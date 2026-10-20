import Foundation
import Testing
@testable import ScopeAdapters

@Suite struct ClaudeSubagentsTests {
    typealias F = ClaudeSubagentFixtures
    typealias N = ClaudeNativeFixtures

    static let t0 = Date(timeIntervalSince1970: 1_792_490_000)

    static func facts(_ stdin: String, at: Date = t0) -> ClaudeHookFacts {
        ClaudeHookFacts(body: JSONValue(json: stdin)!, at: at)
    }

    static func records(_ lines: [String]) -> [ClaudeTranscriptRecord] {
        var tail = ClaudeTranscriptTail()
        return lines.flatMap { tail.records(Data($0.utf8)) }
    }

    static let transcript = [N.agentToolUse, N.agentLaunched, N.agentFinished]

    @Test func backgroundLaunchFromItsHooks() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.postToolUseAsync))
        subagents.apply(Self.facts(F.subagentStart, at: Self.t0.addingTimeInterval(1)))
        #expect(subagents.agents.count == 1)
        let agent = try #require(subagents.agent("a0000000000000001"))
        #expect(agent.id == "a0000000000000001")
        #expect(agent.toolUseID == "toolu_agent1")
        #expect(agent.type == "general-purpose")
        #expect(agent.description == "<text>")
        #expect(agent.model == "claude-haiku-5-5")
        #expect(agent.background == true)
        #expect(agent.state == .running)
        #expect(agent.startedAt == Self.t0)
        #expect(agent.duration(now: Self.t0.addingTimeInterval(30)) == 30)
    }

    @Test func aBackgroundSubagentEndsWithItsNotification() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.records(Self.transcript))
        let agent = try #require(subagents.agents.first)
        #expect(subagents.agents.count == 1)
        #expect(agent.state == .completed)
        #expect(agent.background == true)
        #expect(agent.tokens == 51234)
        #expect(agent.toolUses == 17)
        #expect(agent.durationMs == 93000)
        #expect(agent.duration(now: .distantFuture) == 93)
        #expect(agent.result == "<text>")
        #expect(agent.endedAt != nil)
    }

    @Test func aSubagentStopKeepsTheNotificationsWord() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.postToolUseAsync))
        subagents.apply(Self.facts(F.subagentStop, at: Self.t0.addingTimeInterval(60)))
        var agent = try #require(subagents.agents.first)
        #expect(agent.state == .completed)
        #expect(agent.result == "<last message>")
        #expect(agent.transcriptPath == "/p/session/subagents/agent-a0000000000000001.jsonl")
        // The notification's report is the one Claude Code hands the session: it replaces the last message.
        subagents.apply(Self.records(Self.transcript))
        agent = try #require(subagents.agents.first)
        #expect(subagents.agents.count == 1)
        #expect(agent.result == "<text>")
        #expect(agent.tokens == 51234)
    }

    @Test func claudeCodesOwnAgentsAreIgnored() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.internalSubagentStop))
        #expect(subagents.agents.isEmpty)
        subagents.apply(Self.facts(F.postToolUseAsync))
        subagents.apply(Self.facts(F.internalSubagentStop))
        #expect(subagents.agents.count == 1)
        #expect(subagents.agents.first?.state == .running)
    }

    @Test func aSubagentsOwnToolCallsAddNoEntry() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.postToolUseAsync))
        subagents.apply(Self.facts(F.postToolUseInsideAgent))
        #expect(subagents.agents.count == 1)
    }

    @Test func aForegroundSubagentFromItsHooksInEitherOrder() throws {
        var subagents = ClaudeSubagents()
        // As Claude Code sends them: the sub-agent's stop before the call's own `PostToolUse`.
        subagents.apply(Self.facts(F.syncSubagentStart))
        subagents.apply(Self.facts(F.syncSubagentStop, at: Self.t0.addingTimeInterval(2)))
        subagents.apply(Self.facts(F.postToolUseSync, at: Self.t0.addingTimeInterval(2)))
        #expect(subagents.agents.count == 1)
        let agent = try #require(subagents.agent("a0000000000000002"))
        #expect(agent.state == .completed)
        #expect(agent.background == false)
        #expect(agent.toolUseID == "toolu_agent2")
        #expect(agent.description == "<sync text>")
        #expect(agent.tokens == 27599)
        #expect(agent.durationMs == 1612)
        #expect(agent.toolUses == 0)
        #expect(agent.startedAt == Self.t0)
        // What the call handed back is the report, over the sub-agent's last message.
        #expect(agent.result == "<sync result>")
    }

    @Test func transcriptBeforeHooksIsOneAgent() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.records(Self.transcript))
        subagents.apply(Self.facts(F.subagentStart))
        subagents.apply(Self.facts(F.postToolUseAsync))
        subagents.apply(Self.facts(F.subagentStop))
        #expect(subagents.agents.count == 1)
        let agent = try #require(subagents.agents.first)
        #expect(agent.state == .completed)
        #expect(agent.tokens == 51234)
    }

    @Test func aNotificationNamingOnlyItsCallIsMergedOnceTheIDIsKnown() throws {
        var subagents = ClaudeSubagents()
        // The notification arrives first, keyed by the agent id and its call.
        subagents.apply(Self.records([N.agentFinished]))
        #expect(subagents.agents.count == 1)
        // The transcript's call, seen through a fresh tail (a relaunch), names both.
        subagents.apply(Self.records([N.agentToolUse, N.agentLaunched]))
        #expect(subagents.agents.count == 1)
        #expect(subagents.agents.first?.state == .completed)
        #expect(subagents.agents.first?.description == "<text>")
    }

    @Test func provisionalEntriesMergeWhenAFactNamesBoth() throws {
        var subagents = ClaudeSubagents()
        // A hook names the agent; the meta file names its call; a provisional entry named by the call merges into it.
        subagents.apply(Self.facts(F.subagentStart))
        let input = try #require(JSONValue(json: #"{"description":"<text>","subagent_type":"general-purpose"}"#))
        subagents.apply([.toolCall(ClaudeToolCall(id: "toolu_agent1", name: "Agent", input: input, result: nil, isError: false))])
        #expect(subagents.agents.count == 2)
        let meta = try #require(ClaudeSubagentMeta(json: Data(F.meta.utf8)))
        subagents.apply(meta, agentID: "a0000000000000001", transcriptPath: "/p/agent.jsonl")
        #expect(subagents.agents.count == 1)
        let agent = try #require(subagents.agents.first)
        #expect(agent.toolUseID == "toolu_agent1")
        #expect(agent.depth == 1)
        #expect(agent.background == true)
        #expect(agent.model == "haiku")
        #expect(agent.hasMeta)
        #expect(agent.transcriptPath == "/p/agent.jsonl")
        #expect(subagents.agentsWithoutMeta.isEmpty)
    }

    @Test func metaForAnUnknownAgentIsDropped() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(try #require(ClaudeSubagentMeta(json: Data(F.meta.utf8))), agentID: "a0000000000000001", transcriptPath: nil)
        #expect(subagents.agents.isEmpty)
    }

    @Test func metaReadsTolerantly() throws {
        let meta = try #require(ClaudeSubagentMeta(json: Data(F.metaWorktree.utf8)))
        #expect(meta.spawnDepth == 2)
        #expect(meta.worktreeBranch == "<branch>")
        #expect(meta.requestShape == "foreground")
        #expect(meta.finished == nil)
        #expect(ClaudeSubagentMeta(json: Data("[1]".utf8)) == nil)
        #expect(ClaudeSubagentMeta(json: Data("not json".utf8)) == nil)
        #expect(ClaudeSubagentMeta(json: Data(#"{"spawnDepth":"x","model":3}"#.utf8))?.spawnDepth == nil)
    }

    @Test func aStoppedSubagent() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.records([F.agentKilled]))
        #expect(subagents.agents.first?.state == .stopped)
    }

    @Test func otherBackgroundTasksAreNotSubagents() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.records([N.bashToolUse, N.bashLaunched, N.bashCompleted, N.monitorToolUse, N.monitorLaunched, N.monitorEvent]))
        #expect(subagents.agents.isEmpty)
    }

    @Test func theSessionEndingInterruptsWhatStillRuns() throws {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.sessionStart("startup")))
        subagents.apply(Self.facts(F.postToolUseAsync, at: Self.t0.addingTimeInterval(5)))
        subagents.apply(Self.facts(F.sessionEnd, at: Self.t0.addingTimeInterval(9)))
        let agent = try #require(subagents.agents.first)
        #expect(agent.state == .interrupted)
        #expect(agent.endedAt == Self.t0.addingTimeInterval(9))
        #expect(subagents.runningCount(hookAgents: [:], now: Self.t0.addingTimeInterval(10), limit: 7200) == 0)
    }

    @Test func aRelaunchReadsTheTranscriptBackWithoutGhosts() throws {
        // The process that launched it is gone: the resumed session's transcript says it launched and never reported.
        var subagents = ClaudeSubagents()
        let relaunch = Date(timeIntervalSince1970: 1_800_000_000)
        subagents.apply(Self.facts(F.sessionStart("resume"), at: relaunch))
        subagents.apply(Self.records([N.agentToolUse, N.agentLaunched]))
        #expect(subagents.agents.first?.state == .interrupted)
        #expect(subagents.runningCount(hookAgents: [:], now: relaunch, limit: 7200) == 0)
        // In the other order — transcript first, then the hook — the same.
        var other = ClaudeSubagents()
        other.apply(Self.records([N.agentToolUse, N.agentLaunched]))
        other.apply(Self.facts(F.sessionStart("resume"), at: relaunch))
        #expect(other.agents.first?.state == .interrupted)
        // One that did report stays as it ended.
        var finished = ClaudeSubagents()
        finished.apply(Self.facts(F.sessionStart("resume"), at: relaunch))
        finished.apply(Self.records(Self.transcript))
        #expect(finished.agents.first?.state == .completed)
    }

    @Test func aCompactionIsNotANewProcess() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.sessionStart("startup")))
        subagents.apply(Self.facts(F.postToolUseAsync, at: Self.t0.addingTimeInterval(5)))
        subagents.apply(Self.facts(F.sessionStart("compact"), at: Self.t0.addingTimeInterval(60)))
        #expect(subagents.agents.first?.state == .running)
    }

    @Test func rebuiltFromTheTranscriptFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "subagents-\(UUID().uuidString).jsonl")
        try N.file(Self.transcript).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var tail = ClaudeTranscriptTail()
        var rebuilt = ClaudeSubagents()
        rebuilt.apply(try tail.read(url))
        var live = ClaudeSubagents()
        live.apply(Self.records(Self.transcript))
        #expect(rebuilt == live)
        #expect(rebuilt.agents.first?.state == .completed)
    }

    @Test func theWaitCountsWhatTheHooksAndTheTranscriptAgreeOn() {
        var subagents = ClaudeSubagents()
        let now = Self.t0.addingTimeInterval(100)
        // Started per the hooks, finished per the transcript: no longer at work.
        subagents.apply(Self.records(Self.transcript))
        #expect(subagents.runningCount(hookAgents: ["a0000000000000001": Self.t0], now: now, limit: 7200) == 0)
        // Claude Code's own agent, seen only by the hooks, still counts as before.
        #expect(subagents.runningCount(hookAgents: ["a0000000000000009": Self.t0], now: now, limit: 7200) == 1)
        // Too old to be believed.
        #expect(subagents.runningCount(hookAgents: ["a0000000000000009": Self.t0], now: Self.t0.addingTimeInterval(8000), limit: 7200) == 0)
    }

    @Test func theWaitCountsALaunchWhoseStartHookWasLost() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.sessionStart("startup")))
        subagents.apply(Self.facts(F.postToolUseAsync, at: Self.t0.addingTimeInterval(5)))
        let now = Self.t0.addingTimeInterval(10)
        #expect(subagents.runningCount(hookAgents: [:], now: now, limit: 7200) == 1)
        #expect(subagents.runningCount(hookAgents: ["a0000000000000001": Self.t0.addingTimeInterval(5)], now: now, limit: 7200) == 1)
        // Without a session start seen, only the hooks say: a transcript read back proves nothing about this process.
        var unseen = ClaudeSubagents()
        unseen.apply(Self.facts(F.postToolUseAsync))
        #expect(unseen.runningCount(hookAgents: [:], now: now, limit: 7200) == 0)
    }

    @Test func aNestedLaunchNamesItsParent() throws {
        var subagents = ClaudeSubagents()
        let nested = F.postToolUseAsync
            .replacingOccurrences(of: #""hook_event_name":"PostToolUse""#, with: #""agent_id":"a0000000000000001","agent_type":"general-purpose","hook_event_name":"PostToolUse""#)
            .replacingOccurrences(of: #""agentId":"a0000000000000001""#, with: #""agentId":"a0000000000000005""#)
            .replacingOccurrences(of: "toolu_agent1", with: "toolu_agent5")
        subagents.apply(Self.facts(nested))
        #expect(subagents.agent("a0000000000000005")?.parentID == "a0000000000000001")
    }

    @Test func theListIsBoundedFinishedFirst() {
        var subagents = ClaudeSubagents()
        subagents.apply(Self.facts(F.sessionStart("startup")))
        subagents.apply(Self.facts(F.postToolUseAsync, at: Self.t0.addingTimeInterval(1)))
        for index in 0..<(ClaudeSubagents.limit + 5) {
            let stdin = F.postToolUseSync
                .replacingOccurrences(of: "a0000000000000002", with: "b\(index)")
                .replacingOccurrences(of: "toolu_agent2", with: "toolu_sync\(index)")
            subagents.apply(Self.facts(stdin, at: Self.t0.addingTimeInterval(Double(index + 2))))
        }
        #expect(subagents.agents.count == ClaudeSubagents.limit)
        // The running one, the oldest, is kept.
        #expect(subagents.agents.first?.agentID == "a0000000000000001")
        #expect(subagents.agents.last?.agentID == "b\(ClaudeSubagents.limit + 4)")
    }

    @Test func pathsBesideTheSessionTranscript() {
        let session = "/Users/x/.claude/projects/p/1234.jsonl"
        #expect(ClaudeSubagents.transcriptURL(agentID: "a1", sessionTranscript: session).path
                == "/Users/x/.claude/projects/p/1234/subagents/agent-a1.jsonl")
        #expect(ClaudeSubagents.metaURL(agentID: "a1", sessionTranscript: session).path
                == "/Users/x/.claude/projects/p/1234/subagents/agent-a1.meta.json")
    }

    @Test func aFreshSessionForgetsThePreviousOnesSubagents() {
        var session = ClaudeSession()
        session.apply(Self.facts(F.postToolUseAsync))
        #expect(session.subagents.agents.count == 1)
        session.apply(Self.facts(F.sessionStart("clear")))
        #expect(session.subagents.agents.isEmpty)
        session.apply(Self.records(Self.transcript))
        #expect(session.subagents.agents.count == 1)
    }
}

@Suite struct ClaudeSubagentTailTests {
    typealias F = ClaudeSubagentFixtures

    static func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "subagent-tail-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsTheToolCallsIncrementally() throws {
        let url = try Self.write(ClaudeNativeFixtures.file([F.subagentToolUse("t1", command: "npm test"), F.subagentToolResult]))
        defer { try? FileManager.default.removeItem(at: url) }
        var tail = ClaudeSubagentTail()
        #expect(try tail.read(url))
        #expect(tail.steps.map(\.tool) == ["Bash"])
        #expect(tail.steps.first?.target == "npm test")
        #expect(tail.steps.first?.at != nil)
        #expect(try tail.read(url) == false)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((F.subagentToolUse("t2", tool: "Read") + "\n").utf8))
        try handle.close()
        #expect(try tail.read(url))
        #expect(tail.steps.map(\.id) == ["t1", "t2"])
        #expect(tail.count == 2)
    }

    @Test func keepsTheLastCalls() throws {
        let lines = (0..<(ClaudeSubagentTail.limit + 7)).map { F.subagentToolUse("t\($0)") }
        let url = try Self.write(ClaudeNativeFixtures.file(lines))
        defer { try? FileManager.default.removeItem(at: url) }
        var tail = ClaudeSubagentTail()
        try tail.read(url, chunkSize: 300)
        #expect(tail.steps.count == ClaudeSubagentTail.limit)
        #expect(tail.steps.last?.id == "t\(ClaudeSubagentTail.limit + 6)")
        #expect(tail.count == ClaudeSubagentTail.limit + 7)
    }

    @Test func ignoresWhatIsNotAToolCall() throws {
        let url = try Self.write("not json\n" + ClaudeNativeFixtures.file([F.subagentToolResult, #"{"type":"assistant","message":{"content":"x \"tool_use\""}}"#]))
        defer { try? FileManager.default.removeItem(at: url) }
        var tail = ClaudeSubagentTail()
        #expect(try tail.read(url) == false)
        #expect(tail.steps.isEmpty)
    }
}
