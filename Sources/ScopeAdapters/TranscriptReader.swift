import Foundation

/// One exchange of a Claude Code session, read back from its transcript: what the user asked, what the agent
/// answered, and the tools it ran in between.
public struct TranscriptTurn: Sendable, Equatable {
    public struct Call: Sendable, Equatable {
        public var name: String
        public var target: String?

        public init(name: String, target: String? = nil) {
            self.name = name
            self.target = target
        }
    }

    public var prompt: String
    /// The agent's text, every message of the turn, blank-line separated. Empty when it only ran tools.
    public var reply: String
    public var calls: [Call]
    public var startedAt: Date?
    public var endedAt: Date?

    public init(prompt: String, reply: String = "", calls: [Call] = [], startedAt: Date? = nil, endedAt: Date? = nil) {
        self.prompt = prompt
        self.reply = reply
        self.calls = calls
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Reads the turns out of a Claude Code transcript JSONL, for the reading column's history.
///
/// Tolerant by design: the file's format is Claude Code's own and changes with its versions, so this reads a handful
/// of keys (`type`, `isSidechain`, `isMeta`, `timestamp`, `message.content`), skips every line it does not understand
/// and never fails on one. A user line with text opens a turn; assistant text and tool uses go to the open one;
/// tool results, sub-agent lines (`isSidechain`), meta lines and the `<command-…>` / `<system-reminder>` prompts
/// Claude Code writes for itself are not turns. What this returns is history — never state: a thread's state comes
/// from its hooks, and a transcript that cannot be read leaves the column with the hook's answer alone.
public enum TranscriptReader {
    /// Lines are read this many bytes at a time: a transcript reaches tens of megabytes.
    public static let chunkSize = 1 << 20
    /// Turns kept, the last ones.
    public static let turnLimit = 100
    /// Characters of a turn's prompt and reply kept.
    public static let textLimit = 64 * 1024

    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// The last `limit` turns of `url`. Throws only when the file cannot be opened.
    public static func read(_ url: URL, limit: Int = turnLimit, chunkSize: Int = chunkSize) throws -> [TranscriptTurn] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var turns: [TranscriptTurn] = []
        var pending = Data()
        func take(_ line: Data) {
            fold(line, into: &turns)
            if turns.count > limit + 20 { turns.removeFirst(turns.count - limit) }
        }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            for line in pending[pending.startIndex...lastNewline].split(separator: 0x0A, omittingEmptySubsequences: true) {
                take(Data(line))
            }
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        if !pending.isEmpty { take(pending) }
        return Array(turns.suffix(limit))
    }

    /// Folds one transcript line into `turns`; a line that is not a prompt, an answer or a tool use changes nothing.
    static func fold(_ line: Data, into turns: inout [TranscriptTurn]) {
        let isUser = line.range(of: userMarker) != nil
        guard isUser || line.range(of: assistantMarker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return }
        let at = (object["timestamp"] as? String).flatMap(TranscriptUsage.parseDate)
        if type == "user" {
            guard let prompt = promptText(message["content"]) else { return }
            turns.append(TranscriptTurn(prompt: String(prompt.prefix(textLimit)), startedAt: at, endedAt: at))
            return
        }
        guard !turns.isEmpty, let blocks = message["content"] as? [[String: Any]] else { return }
        var turn = turns[turns.count - 1]
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                turn.reply = turn.reply.isEmpty ? text : turn.reply + "\n\n" + text
                if turn.reply.count > textLimit { turn.reply = "…" + turn.reply.suffix(textLimit) }
            case "tool_use":
                guard let name = block["name"] as? String, !name.isEmpty else { continue }
                turn.calls.append(TranscriptTurn.Call(name: name, target: HookStdin.toolTarget(tool: name, input: block["input"] as? [String: Any])))
            default:
                continue
            }
        }
        if let at { turn.endedAt = at }
        turns[turns.count - 1] = turn
    }

    /// The user's own words on a user line: a string, or the `text` blocks of a content array that holds no tool
    /// result. `nil` for a tool result and for the prompts Claude Code writes for itself (they open with a tag).
    static func promptText(_ content: Any?) -> String? {
        var text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }
}
