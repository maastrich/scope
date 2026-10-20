import Foundation

/// The last tools a sub-agent ran, read from its own transcript (`agent-<id>.jsonl`) incrementally — from where the
/// last read stopped, complete lines only — for the detail of one sub-agent. `ClaudeTranscriptTail` skips every
/// sidechain line, and a sub-agent's transcript holds nothing else; this one reads only its tool calls.
///
/// A file read for the first time is read from at most `backlog` bytes before its end: only the last `limit` calls
/// are kept, and a sub-agent can write megabytes.
public struct ClaudeSubagentTail: Sendable, Equatable {
    public struct Step: Sendable, Equatable, Identifiable {
        /// The call's `tool_use` id.
        public var id: String
        public var tool: String
        /// `HookStdin.toolTarget`: the file, the command's first line, the pattern, …
        public var target: String?
        public var at: Date?
    }

    public private(set) var path: String?
    public private(set) var offset: UInt64 = 0
    /// Oldest first, at most `limit`.
    public private(set) var steps: [Step] = []
    /// Calls seen in all, including the ones dropped from `steps`.
    public private(set) var count = 0

    public static let limit = 20
    public static let backlog: UInt64 = 2 << 20

    public init() {}

    /// Reads what `url` gained since the last read; `true` when `steps` moved. A different file, or one shorter than
    /// the offset (rewritten), starts over. Throws when the file cannot be opened.
    @discardableResult
    public mutating func read(_ url: URL, chunkSize: Int = ClaudeTranscriptTail.chunkSize) throws -> Bool {
        if path != url.path {
            self = ClaudeSubagentTail()
            path = url.path
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset {
            self = ClaudeSubagentTail()
            path = url.path
        }
        guard offset < size else { return false }
        // A first read starts in the middle of a line, dropped below with whatever precedes the first newline.
        var skipFirstLine = false
        if offset == 0, size > Self.backlog {
            offset = size - Self.backlog
            skipFirstLine = true
        }
        try handle.seek(toOffset: offset)
        let before = steps
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            var lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true)[...]
            if skipFirstLine, complete.first != 0x0A { lines = lines.dropFirst() }
            skipFirstLine = false
            for line in lines { take(line) }
            offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        return steps != before
    }

    private static let marker = Data("\"tool_use\"".utf8)

    mutating func take(_ line: some DataProtocol) {
        let data = Data(line)
        guard data.range(of: Self.marker) != nil, let json = JSONValue(json: data), json["type"]?.string == "assistant" else { return }
        let at = json["timestamp"]?.string.flatMap(TranscriptUsage.parseDate)
        for block in json["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
            guard let name = block["name"]?.nonEmptyString else { continue }
            let id = block["id"]?.nonEmptyString ?? "\(count)"
            let target = HookStdin.toolTarget(tool: name, input: block["input"]?.anyValue as? [String: Any])
            count += 1
            steps.append(Step(id: id, tool: name, target: target, at: at))
            if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
        }
    }
}
