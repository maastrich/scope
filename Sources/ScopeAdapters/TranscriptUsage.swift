import Foundation

/// Tokens one or more model calls consumed, as Claude Code's transcript reports them in `message.usage`.
public struct TokenCounts: Codable, Sendable, Equatable, Hashable {
    /// Uncached input.
    public var input: Int
    public var output: Int
    /// Input written to the prompt cache, both lifetimes.
    public var cacheCreation: Int
    /// The part of `cacheCreation` written for an hour rather than five minutes: it is priced higher.
    public var cacheCreation1h: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheCreation1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheCreation1h = cacheCreation1h
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    /// Everything the model read or wrote, cache reads included — what `ccusage` and the like call total tokens.
    /// Cache reads usually dominate it; the breakdown is there to say so.
    public var total: Int { input + output + cacheCreation + cacheRead }

    public var isZero: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                    cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

/// One model call read from a transcript.
public struct TranscriptUsageEntry: Sendable, Equatable {
    /// `message.id`, the same on every line Claude Code writes for one response (one line per content block).
    public var id: String
    public var model: String
    public var at: Date
    public var counts: TokenCounts

    public init(id: String, model: String, at: Date, counts: TokenCounts) {
        self.id = id
        self.model = model
        self.at = at
        self.counts = counts
    }
}

/// Reads the model calls out of Claude Code transcript JSONL, from a byte offset on, so a file is never read twice.
///
/// A response is written as one `"type":"assistant"` line per content block (thinking, text, each tool use), every
/// one carrying the same `message.id` and the same `usage`: the lines are returned as they are and deduplicated by
/// whoever sums them (`TokenLedger`), since the lines of one response can straddle two reads. Only the top-level
/// usage fields are read; `usage.iterations` repeats them.
public enum TranscriptUsage {
    /// What a read found, and where the next one starts: just past the last complete line, since the one after it
    /// may still be being written.
    public struct Read: Sendable, Equatable {
        public var entries: [TranscriptUsageEntry]
        public var offset: UInt64
        /// The file was shorter than the offset asked for (rewritten, or another file under the same name), so it
        /// was read from its start.
        public var restarted: Bool
    }

    /// Lines are read this many bytes at a time: a transcript reaches tens of megabytes.
    public static let chunkSize = 1 << 20

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// The complete lines of `url` from `offset` on. Throws when the file cannot be opened.
    public static func read(_ url: URL, from offset: UInt64, chunkSize: Int = chunkSize) throws -> Read {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let restarted = size < offset
        var position = restarted ? 0 : offset
        guard position < size else { return Read(entries: [], offset: position, restarted: restarted) }
        try handle.seek(toOffset: position)

        var entries: [TranscriptUsageEntry] = []
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let entry = entry(line) { entries.append(entry) }
            }
            position += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        return Read(entries: entries, offset: position, restarted: restarted)
    }

    /// The model call on one transcript line; `nil` for every other kind of line, a line without usage, and the
    /// `<synthetic>` placeholders Claude Code writes for calls that never reached the API.
    public static func entry(_ line: some DataProtocol) -> TranscriptUsageEntry? {
        let data = Data(line)
        guard data.range(of: assistantMarker) != nil,
              let decoded = try? JSONDecoder().decode(Line.self, from: data),
              decoded.type == "assistant", let message = decoded.message, let usage = message.usage,
              let model = message.model, model != "<synthetic>",
              let id = message.id ?? decoded.requestId ?? decoded.uuid,
              let stamp = decoded.timestamp, let at = parseDate(stamp) else { return nil }
        let counts = TokenCounts(input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
                                 cacheCreation: usage.cache_creation_input_tokens ?? 0,
                                 cacheCreation1h: usage.cache_creation?.ephemeral_1h_input_tokens ?? 0,
                                 cacheRead: usage.cache_read_input_tokens ?? 0)
        guard !counts.isZero else { return nil }
        return TranscriptUsageEntry(id: id, model: model, at: at, counts: counts)
    }

    /// The transcripts of the subagents a session ran (the Task tool): `<dir>/<session>/subagents/*.jsonl` beside
    /// `<dir>/<session>.jsonl`. They spend the same quota as the session, so they count towards its thread.
    public static func subagentTranscripts(of transcript: URL) -> [URL] {
        let folder = transcript.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted()
            .map { folder.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// `2026-09-15T12:08:40.424Z`, with or without the fraction.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: .iso8601)
    }

    // The few fields read; everything else on the line is skipped by the decoder.
    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var requestId: String?
        var uuid: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation: CacheCreation?
    }

    private struct CacheCreation: Decodable {
        var ephemeral_1h_input_tokens: Int?
    }
}
