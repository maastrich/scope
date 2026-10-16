import Foundation
import Testing
@testable import ScopeAdapters

/// `TranscriptReader`: the turns of a session read back from its transcript, tolerant of everything else in it.
@Suite struct TranscriptReaderTests {
    typealias F = TranscriptFixtures

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func user(_ content: Any, at: String = "2026-09-15T12:08:37.215Z", extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": content], "timestamp": at, "uuid": UUID().uuidString]
        object.merge(extra) { $1 }
        return line(object)
    }

    static func assistant(_ blocks: [[String: Any]], at: String = "2026-09-15T12:08:41.116Z", extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": blocks], "timestamp": at, "uuid": UUID().uuidString]
        object.merge(extra) { $1 }
        return line(object)
    }

    static func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reader-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    @Test func promptsOpenTurnsAndAnswersAndToolsFillThem() throws {
        let url = try Self.file([
            Self.user("Fix the reset of lastReply"),
            Self.assistant([["type": "thinking", "thinking": "…"], ["type": "text", "text": "Reading the fold first."]]),
            Self.assistant([["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/w/ThreadActivity.swift"]]]),
            Self.user([["type": "tool_result", "tool_use_id": "t1", "content": "…"]]),
            Self.assistant([["type": "tool_use", "id": "t2", "name": "Holodeck", "input": ["scene": "reader-test", "steps": 3]]]),
            Self.user([["type": "tool_result", "tool_use_id": "t2", "content": "…"]]),
            Self.assistant([["type": "text", "text": "Done: the reset now happens on `turn.ended`."]], at: "2026-09-15T12:09:02.000Z"),
            Self.user([["type": "text", "text": "Thanks, now the tests"]], at: "2026-09-15T12:10:00.000Z"),
            Self.assistant([["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "swift test --filter ThreadActivityTests\nexit"]]]),
        ])
        let turns = try TranscriptReader.read(url)
        #expect(turns.count == 2)
        #expect(turns[0].prompt == "Fix the reset of lastReply")
        #expect(turns[0].reply == "Reading the fold first.\n\nDone: the reset now happens on `turn.ended`.")
        #expect(turns[0].calls == [.init(name: "Read", target: "/w/ThreadActivity.swift"), .init(name: "Holodeck", target: nil)])
        #expect(abs((turns[0].startedAt?.timeIntervalSince1970 ?? 0) - 1_789_474_117.215) < 0.001)
        #expect(turns[0].endedAt == Date(timeIntervalSince1970: 1_789_474_142))
        #expect(turns[1].prompt == "Thanks, now the tests")
        #expect(turns[1].reply.isEmpty)
        #expect(turns[1].calls == [.init(name: "Bash", target: "swift test --filter ThreadActivityTests")])
    }

    @Test func whatIsNotAnExchangeIsSkippedAndNothingBreaksTheRead() throws {
        let url = try Self.file([
            "not json at all",
            #"{"type":"summary","summary":"earlier"}"#,
            Self.user("<command-name>/clear</command-name>"),
            Self.user("<system-reminder>…</system-reminder>"),
            Self.user("A real prompt"),
            Self.user("Sub-agent prompt", extra: ["isSidechain": true]),
            Self.assistant([["type": "text", "text": "Side text"]], extra: ["isSidechain": true]),
            Self.user("Meta prompt", extra: ["isMeta": true]),
            Self.assistant([["type": "text", "text": "   "]]),
            Self.assistant([["type": "unknown_block", "data": 1], ["type": "text", "text": "Real answer"]]),
            #"{"type":"assistant","message":{"content":"a string, not blocks"}}"#,
            F.toolResult,
        ])
        let turns = try TranscriptReader.read(url)
        #expect(turns.map(\.prompt) == ["A real prompt"])
        #expect(turns[0].reply == "Real answer")
        #expect(turns[0].calls.isEmpty)
    }

    @Test func onlyTheLastTurnsAreKeptAndAMissingFileThrows() throws {
        let lines = (0..<30).flatMap { ["Prompt \($0)"].map { Self.user($0) } + [Self.assistant([["type": "text", "text": "Answer"]])] }
        let turns = try TranscriptReader.read(try Self.file(lines), limit: 5, chunkSize: 64)
        #expect(turns.map(\.prompt) == ["Prompt 25", "Prompt 26", "Prompt 27", "Prompt 28", "Prompt 29"])
        #expect(turns.allSatisfy { $0.reply == "Answer" })
        #expect(throws: (any Error).self) { try TranscriptReader.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")) }
    }
}
