import Foundation
import Testing
@testable import ScopeAdapters

/// `TranscriptUsage`: the model calls read out of a Claude Code transcript, from a byte offset on.
@Suite struct TranscriptUsageTests {
    typealias F = TranscriptFixtures

    static func temporaryFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func anAssistantLineGivesItsMessageModelTimeAndTopLevelUsage() throws {
        let entry = try #require(TranscriptUsage.entry(Data(F.response1Thinking.utf8)))
        #expect(entry.id == "msg_00000000000000000000000006")
        #expect(entry.model == "claude-fable-5-1")
        #expect(entry.at == Date(timeIntervalSince1970: 1_789_474_120.424))
        // `usage.iterations` repeats the same numbers: read once, not twice.
        #expect(entry.counts == TokenCounts(input: 2, output: 316, cacheCreation: 26_812, cacheCreation1h: 26_812, cacheRead: 29_250))
        #expect(entry.counts.total == 2 + 316 + 26_812 + 29_250)
    }

    @Test func promptsToolResultsAndSyntheticCallsAreNotModelCalls() {
        #expect(TranscriptUsage.entry(Data(F.prompt.utf8)) == nil)
        #expect(TranscriptUsage.entry(Data(F.toolResult.utf8)) == nil)
        #expect(TranscriptUsage.entry(Data(F.synthetic.utf8)) == nil)
        #expect(TranscriptUsage.entry(Data("not json \"type\":\"assistant\"".utf8)) == nil)
    }

    @Test func everyContentBlockLineIsReturnedForTheLedgerToDeduplicate() throws {
        let url = try Self.temporaryFile(F.file([F.prompt, F.response1Thinking, F.response1Text, F.response1ToolUse, F.toolResult, F.response2]))
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try TranscriptUsage.read(url, from: 0)
        #expect(read.entries.map(\.id) == Array(repeating: "msg_00000000000000000000000006", count: 3) + ["msg_00000000000000000000000013"])
        #expect(read.offset == UInt64(try Data(contentsOf: url).count))
        #expect(!read.restarted)
    }

    @Test func aLineStillBeingWrittenIsLeftForTheNextRead() throws {
        let complete = F.file([F.response1Thinking])
        let partial = String(F.response2.prefix(80))
        let url = try Self.temporaryFile(complete + partial)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try TranscriptUsage.read(url, from: 0)
        #expect(first.entries.count == 1)
        #expect(first.offset == UInt64(complete.utf8.count))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(F.response2.dropFirst(80)) + "\n").utf8))
        try handle.close()

        let second = try TranscriptUsage.read(url, from: first.offset)
        #expect(second.entries.map(\.id) == ["msg_00000000000000000000000013"])
        #expect(second.offset == UInt64(try Data(contentsOf: url).count))
    }

    @Test func smallChunksReadTheSameLines() throws {
        let url = try Self.temporaryFile(F.file([F.prompt, F.response1Thinking, F.response1Text, F.response2]))
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try TranscriptUsage.read(url, from: 0)
        let chunked = try TranscriptUsage.read(url, from: 0, chunkSize: 97)
        #expect(chunked == whole)
    }

    @Test func aFileShorterThanTheOffsetIsReadFromItsStart() throws {
        let url = try Self.temporaryFile(F.file([F.response2]))
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try TranscriptUsage.read(url, from: 1_000_000)
        #expect(read.restarted)
        #expect(read.entries.count == 1)
    }

    @Test func nothingNewReadsNothing() throws {
        let text = F.file([F.response2])
        let url = try Self.temporaryFile(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try TranscriptUsage.read(url, from: UInt64(text.utf8.count))
        #expect(read.entries.isEmpty)
        #expect(read.offset == UInt64(text.utf8.count))
    }

    @Test func subagentTranscriptsSitInAFolderNamedAfterTheSession() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let subagents = dir.appending(path: "9b1d/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        for name in ["agent-b.jsonl", "agent-a.jsonl", "agent-a.meta.json"] {
            try Data().write(to: subagents.appending(path: name))
        }
        let found = TranscriptUsage.subagentTranscripts(of: dir.appending(path: "9b1d.jsonl"))
        #expect(found.map(\.lastPathComponent) == ["agent-a.jsonl", "agent-b.jsonl"])
        #expect(TranscriptUsage.subagentTranscripts(of: dir.appending(path: "other.jsonl")).isEmpty)
    }
}
