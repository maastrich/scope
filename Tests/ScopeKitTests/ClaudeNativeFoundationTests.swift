import Foundation
import Testing
@testable import ScopeAdapters
import ScopeCore

@Suite struct JSONValueTests {
    @Test func readsWhatJSONSerializationGives() throws {
        let value = try #require(JSONValue(json: #"{"a":1,"b":true,"c":"x","d":[1,null],"e":{"f":2.5}}"#))
        #expect(value["a"]?.int == 1)
        #expect(value["b"]?.bool == true)
        #expect(value["a"]?.bool == nil)
        #expect(value["c"]?.string == "x")
        #expect(value["d"]?[1]?.isNull == true)
        #expect(value["e"]?["f"]?.double == 2.5)
        #expect(value["missing"] == nil)
        #expect(value["c"]?["nested"] == nil)
    }

    @Test func notJSONIsNil() {
        #expect(JSONValue(json: "not json") == nil)
        #expect(JSONValue(json: "") == nil)
    }

    @Test func clampBoundsStringsArraysAndDepth() throws {
        let long = String(repeating: "x", count: 50)
        let value = try #require(JSONValue(json: #"{"s":"\#(long)","a":[1,2,3,4,5],"deep":{"deeper":{"deepest":1}}}"#))
        let clamped = value.clamped(stringLimit: 10, arrayLimit: 2, depth: 2)
        #expect(clamped["s"]?.string == String(repeating: "x", count: 9) + "…")
        #expect(clamped["a"]?.array?.count == 2)
        #expect(clamped["deep"]?["deeper"]?.isNull == true)
    }

    @Test func roundTripsThroughCodable() throws {
        let value = try #require(JSONValue(json: #"{"a":[1,"two",false,null],"b":{"c":"d"}}"#))
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(JSONValue(json: value.jsonString) == value)
    }
}

@Suite struct ClaudeHookFactsTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!

    static func event(_ kind: HookEvent.Kind, payload: [String: String] = [:], raw: String? = nil) -> AdapterEvent {
        AdapterEvent(threadID: thread, kind: kind, payload: payload, raw: raw, receivedAt: Date(timeIntervalSince1970: 1000))
    }

    @Test func liftsTheSharedFields() throws {
        let stdin = #"{"hook_event_name":"PostToolUse","session_id":"s-1","permission_mode":"auto","effort":{"level":"high"},"tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"npm run dev","run_in_background":true},"tool_response":{"backgroundTaskId":"b00000001","stdout":""}}"#
        let wire = try #require(ClaudeHookFacts.wirePayload(from: Data(stdin.utf8)))
        let facts = try #require(ClaudeHookFacts.from(Self.event(.turnStarted, payload: [HookEvent.hookKey: wire])))
        #expect(facts.event == "PostToolUse")
        #expect(facts.sessionID == "s-1")
        #expect(facts.permissionMode == "auto")
        #expect(facts.effort == "high")
        #expect(facts.toolName == "Bash")
        #expect(facts.toolUseID == "toolu_1")
        #expect(facts.toolInput?["run_in_background"]?.bool == true)
        #expect(facts.toolResponse?["backgroundTaskId"]?.string == "b00000001")
        #expect(facts.backgroundTasks == nil)
    }

    @Test func stopCarriesBackgroundTasksAndCrons() throws {
        let stdin = #"{"hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"dev server","command":"npm run dev"},{"id":"a1","type":"subagent","status":"running","description":"review","agent_type":"Explore"}],"session_crons":[]}"#
        let facts = try #require(ClaudeHookFacts.from(Self.event(.turnEnded, raw: stdin)))
        #expect(facts.backgroundTasks?.count == 2)
        #expect(facts.backgroundTasks?.first?["type"]?.string == "shell")
        #expect(facts.sessionCrons == [])
    }

    @Test func subagentStopNamesTheAgentAndItsTranscript() throws {
        let stdin = #"{"hook_event_name":"SubagentStop","agent_id":"a0000000000000001","agent_type":"Explore","agent_transcript_path":"/tmp/s/subagents/agent-a0000000000000001.jsonl","last_assistant_message":"done"}"#
        let facts = try #require(ClaudeHookFacts.from(Self.event(.agentEnded, raw: stdin)))
        #expect(facts.agentID == "a0000000000000001")
        #expect(facts.agentType == "Explore")
        #expect(facts.agentTranscriptPath?.hasSuffix("agent-a0000000000000001.jsonl") == true)
    }

    @Test func aHugeResponseIsClampedToFitAndStillParses() throws {
        let big = String(repeating: "line of output\\n", count: 40_000)
        let stdin = #"{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"file":{"content":"\#(big)"}},"tool_input":{"file_path":"/x"}}"#
        #expect(stdin.utf8.count > ClaudeHookFacts.wireLimit)
        let wire = try #require(ClaudeHookFacts.wirePayload(from: Data(stdin.utf8)))
        #expect(wire.utf8.count <= ClaudeHookFacts.wireLimit)
        let facts = try #require(ClaudeHookFacts.from(Self.event(.turnStarted, payload: [HookEvent.hookKey: wire])))
        #expect(facts.toolInput?["file_path"]?.string == "/x")
        #expect((facts.toolResponse?["file"]?["content"]?.string?.count ?? 0) <= 2000)
    }

    @Test func notAClaudeHookIsNil() {
        #expect(ClaudeHookFacts.wirePayload(from: Data(#"{"type":"agent-turn-complete"}"#.utf8)) == nil)
        #expect(ClaudeHookFacts.wirePayload(from: Data("plain".utf8)) == nil)
        #expect(ClaudeHookFacts.from(Self.event(.turnEnded)) == nil)
        #expect(ClaudeHookFacts.from(Self.event(.turnEnded, raw: #"{"hook_event_name":"Stop""#)) == nil)
    }
}

@Suite struct ClaudeTranscriptTailTests {
    typealias F = ClaudeNativeFixtures

    static func read(_ lines: [String]) throws -> (records: [ClaudeTranscriptRecord], tail: ClaudeTranscriptTail) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try F.file(lines).write(to: url, atomically: true, encoding: .utf8)
        var tail = ClaudeTranscriptTail()
        return (try tail.read(url), tail)
    }

    @Test func aBackgroundAgentLaunchIsATrackedCall() throws {
        let records = try Self.read([F.agentToolUse, F.agentLaunched]).records
        guard case .toolCall(let call) = try #require(records.first) else { Issue.record("not a call"); return }
        #expect(records.count == 1)
        #expect(call.id == "toolu_agent1")
        #expect(call.name == "Agent")
        #expect(call.input["subagent_type"]?.string == "general-purpose")
        #expect(call.result?["status"]?.string == "async_launched")
        #expect(call.result?["agentId"]?.string == "a0000000000000001")
        #expect(call.startedAt != nil && call.endedAt != nil)
    }

    @Test func aBackgroundCommandAndAMonitorAreTrackedCalls() throws {
        let records = try Self.read([F.bashToolUse, F.bashLaunched, F.monitorToolUse, F.monitorLaunched]).records
        let calls = records.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
        #expect(calls.map(\.name) == ["Bash", "Monitor"])
        #expect(calls[0].result?["backgroundTaskId"]?.string == "b00000001")
        #expect(calls[1].result?["taskId"]?.string == "b00000002")
        #expect(calls[1].result?["timeoutMs"]?.int == 600_000)
    }

    @Test func aForegroundCommandIsNotTracked() throws {
        let use = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-10-20T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_fg","name":"Bash","input":{"command":"ls"}}]}}"#
        let result = #"{"type":"user","isSidechain":false,"timestamp":"2026-10-20T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_fg","content":"x"}]},"toolUseResult":{"stdout":"x","stderr":"","interrupted":false}}"#
        #expect(try Self.read([use, result]).records.isEmpty)
    }

    @Test func aSubagentNotificationCarriesItsUsage() throws {
        let records = try Self.read([F.agentFinished]).records
        guard case .taskNotification(let note) = try #require(records.first) else { Issue.record("not a notification"); return }
        #expect(note.taskID == "a0000000000000001")
        #expect(note.toolUseID == "toolu_agent1")
        #expect(note.status == "completed")
        #expect(note.summary?.hasPrefix("Agent \"") == true)
        #expect(note.result == "<text>")
        #expect(note.tokens == 51234)
        #expect(note.toolUses == 17)
        #expect(note.durationMs == 93000)
    }

    @Test func aNotificationWrittenTwiceIsReturnedOnce() throws {
        let records = try Self.read([F.bashCompletedQueued, F.bashCompleted]).records
        #expect(records.count == 1)
        guard case .taskNotification(let note) = try #require(records.first) else { Issue.record("not a notification"); return }
        #expect(note.taskID == "b00000001")
        #expect(note.summary?.contains("exit code 0") == true)
    }

    @Test func aMonitorEventHasNoStatus() throws {
        guard case .taskNotification(let note) = try #require(try Self.read([F.monitorEvent]).records.first) else {
            Issue.record("not a notification"); return
        }
        #expect(note.taskID == "b00000002")
        #expect(note.status == nil)
        #expect(note.event == "<text>")
    }

    @Test func readsTheSessionRecords() throws {
        let records = try Self.read([F.taskStatus, F.compactBoundary, F.permissionMode, F.prLink, F.costState, F.turnDuration,
                                     F.mcpServers]).records
        #expect(records.count == 7)
        guard case .taskStatus(let status) = records[0], case .compaction(let compaction) = records[1],
              case .permissionMode(let mode) = records[2], case .pullRequest(let pr) = records[3],
              case .cost(let cost) = records[4], case .turnDuration(let turn) = records[5],
              case .mcpServers(let mcp) = records[6] else { Issue.record("unexpected records \(records)"); return }
        #expect(status.taskID == "b00000001" && status.taskType == "local_bash" && status.status == "running")
        #expect(status.toolUseID == "toolu_bash1")
        #expect(compaction.trigger == "auto" && compaction.preTokens == 167_000 && compaction.postTokens == 21_000)
        #expect(mode == "bypassPermissions")
        #expect(pr.number == 42 && pr.repository == "<owner>/<repo>")
        #expect(cost.totalCostUSD == 1.25 && cost.linesAdded == 120 && cost.linesRemoved == 30)
        #expect(turn.pendingBackgroundAgents == 2)
        #expect(mcp.pending == ["server-a"] && mcp.needsAuth == ["server-c"])
        #expect(mcp.failed.first?.code == "CONNECTION_CLOSED")
    }

    @Test func unknownAndBrokenLinesAreSkipped() throws {
        let records = try Self.read([#"{"type":"some-future-record","task-notification":1}"#, "{not json task_status",
                                     #"{"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["x"]}}"#,
                                     #"{"type":"user","isSidechain":true,"origin":{"kind":"task-notification"},"message":{"content":"<task-notification><task-id>x</task-id></task-notification>"}}"#,
                                     F.permissionMode]).records
        #expect(records == [.permissionMode("bypassPermissions")])
    }

    @Test func readsOnlyWhatTheFileGainedAndWaitsForAWholeLine() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try F.file([F.bashToolUse]).write(to: url, atomically: true, encoding: .utf8)
        var tail = ClaudeTranscriptTail()
        #expect(try tail.read(url).isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let half = F.bashLaunched.prefix(F.bashLaunched.count / 2)
        try handle.write(contentsOf: Data(half.utf8))
        #expect(try tail.read(url).isEmpty)
        try handle.write(contentsOf: Data((F.bashLaunched.dropFirst(half.count) + "\n").utf8))
        try handle.close()
        let records = try tail.read(url)
        #expect(records.count == 1)
        #expect(try tail.read(url).isEmpty)
    }
}

@Suite struct ClaudeSessionTests {
    static func facts(_ json: String) -> ClaudeHookFacts {
        ClaudeHookFacts(body: JSONValue(json: json)!, at: .now)
    }

    @Test func followsThePermissionModeFromHooksAndTranscript() {
        var session = ClaudeSession()
        session.apply(Self.facts(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","permission_mode":"plan"}"#))
        #expect(session.permissionMode == "plan")
        #expect(session.sessionID == "s")
        session.apply([.permissionMode("auto")])
        #expect(session.permissionMode == "auto")
    }

    @Test func aSubagentsModeIsNotTheSessions() {
        var session = ClaudeSession()
        session.apply(Self.facts(#"{"hook_event_name":"PostToolUse","permission_mode":"auto","effort":{"level":"high"}}"#))
        session.apply(Self.facts(#"{"hook_event_name":"PostToolUse","agent_id":"a1","permission_mode":"bypassPermissions","effort":{"level":"low"}}"#))
        #expect(session.permissionMode == "auto")
        #expect(session.effort == "high")
    }

    @Test func aFreshConversationStartsOver() {
        var session = ClaudeSession()
        session.apply(Self.facts(#"{"hook_event_name":"PostToolUse","session_id":"s1","permission_mode":"auto"}"#))
        session.apply(Self.facts(#"{"hook_event_name":"SessionStart","session_id":"s1","source":"compact"}"#))
        #expect(session.permissionMode == "auto")
        session.apply(Self.facts(#"{"hook_event_name":"SessionStart","session_id":"s2","source":"clear"}"#))
        #expect(session.permissionMode == nil)
        #expect(session.sessionID == "s2")
    }
}
