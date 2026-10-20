import Foundation
import Testing
@testable import ScopeAdapters
@testable import ScopeControl
import ScopeCore

private typealias F = ClaudeSessionStateFixtures

private func facts(_ json: String, at: Date = Date(timeIntervalSince1970: 1000)) -> ClaudeHookFacts {
    ClaudeHookFacts(body: JSONValue(json: json)!, at: at)
}

/// What one transcript line gives, through a fresh tail.
private func records(_ lines: String...) -> [ClaudeTranscriptRecord] {
    var tail = ClaudeTranscriptTail()
    return lines.flatMap { tail.records(Data($0.utf8)) }
}

@Suite struct ClaudeMCPServersTests {
    private func server(_ servers: ClaudeMCPServers, _ name: String) throws -> ClaudeMCPServers.Server {
        try #require(servers.servers.first { $0.name == name }, "no \(name) in \(servers.servers.map(\.name))")
    }

    @Test func serverNamesBecomeToolNameKeys() {
        #expect(MCPServerKey.key("claude.ai Claude Docs") == "claude_ai_Claude_Docs")
        #expect(MCPServerKey.key("plugin:design:figma") == "plugin_design_figma")
        #expect(MCPServerKey.key("claude-in-chrome") == "claude-in-chrome")
        #expect(MCPServerKey.server(ofTool: "mcp__claude_ai_Linear__list_issues") == "claude_ai_Linear")
        #expect(MCPServerKey.toolName("mcp__scope__scope_thread_wait") == "scope_thread_wait")
        #expect(MCPServerKey.server(ofTool: "Bash") == nil)
        #expect(MCPServerKey.server(ofTool: "mcp__broken") == nil)
    }

    @Test func pendingThenSettledThenToolsOnly() throws {
        var servers = ClaudeMCPServers()
        servers.apply(records(F.mcpAllPending))
        #expect(servers.servers.count == 4)
        #expect(servers.servers.allSatisfy { $0.status == .pending && !$0.isInferred })
        #expect(try server(servers, "plugin:design:figma").source == .plugin)
        #expect(try server(servers, "claude.ai Linear").source == .claudeAI)

        servers.apply(records(F.mcpSettled))
        let a = try server(servers, "server-a")
        #expect(a.status == .connected && a.isInferred && a.evidence == .toolsListed && a.tools == 2)
        let b = try server(servers, "server-b")
        #expect(b.status == .failed && !b.isInferred && b.errorCode == "CONNECTION_CLOSED" && b.error == "<text>")
        let figma = try server(servers, "plugin:design:figma")
        #expect(figma.status == .needsAuth && figma.isInferred && figma.evidence == .toolsListed)
        // Its tools are called `claude_ai_Linear`, it reported as `claude.ai Linear`: one server, not two.
        let linear = try server(servers, "claude.ai Linear")
        #expect(linear.status == .connected && linear.tools == 1)
        #expect(servers.servers.count == 4)
        #expect(servers.failedServers.map(\.name) == ["server-b"])

        let settled = servers
        servers.apply(records(F.mcpToolsOnly))
        #expect(servers == settled, "a delta without server lists changes nothing")
    }

    @Test func aListLeftOutIsKeptAndOneCarriedReplacesIt() throws {
        var servers = ClaudeMCPServers()
        servers.apply(records(F.mcpNeedsAuth))
        #expect(try server(servers, "server-c").status == .needsAuth)
        // The next delta carries pending and failed only: server-c still waits.
        servers.apply(records(F.mcpSettled))
        #expect(try server(servers, "server-c").status == .needsAuth)
        #expect(try server(servers, "server-c").isInferred == false)
    }

    @Test func aDeclaredServerIsUnknownUntilADeltaThenConnectedWhenNoListHasIt() throws {
        var servers = ClaudeMCPServers()
        servers.declare([.init(name: "server-z", source: .user, transport: "http")])
        let before = try server(servers, "server-z")
        #expect(before.status == .unknown && before.source == .user && before.transport == "http")
        servers.apply(records(F.mcpAllPending))
        servers.apply(records(F.mcpSettled))
        let after = try server(servers, "server-z")
        #expect(after.status == .connected && after.isInferred && after.evidence == .notReported)
    }

    @Test func callsAreCountedPerServerFromToolHooks() throws {
        var servers = ClaudeMCPServers()
        servers.apply(facts(F.mcpToolCall))
        servers.apply(facts(F.mcpToolFailure))
        servers.apply(facts(F.prCreated))
        let d = try server(servers, "server-d")
        #expect(d.toolCalls == 2)
        #expect(d.status == .connected && d.evidence == .toolCalled)
        #expect(servers.servers.count == 1)
    }

    @Test func removedToolsAreForgotten() throws {
        var servers = ClaudeMCPServers()
        servers.apply([.mcpServers(ClaudeMCPServerReport(pending: [], failed: [], needsAuth: [], carriesPending: false,
                                                         carriesFailed: false, carriesNeedsAuth: false,
                                                         addedTools: ["mcp__x__a", "mcp__x__b"]))])
        #expect(try server(servers, "x").tools == 2)
        servers.apply([.mcpServers(ClaudeMCPServerReport(pending: [], failed: [], needsAuth: [], carriesPending: false,
                                                         carriesFailed: false, carriesNeedsAuth: false,
                                                         removedTools: ["mcp__x__a", "mcp__x__b"]))])
        #expect(servers.servers.isEmpty)
    }

    @Test func theSessionCarriesItAndAFreshStartForgetsIt() {
        var session = ClaudeSession()
        session.apply(records(F.mcpAllPending))
        #expect(session.mcpServers.servers.count == 4)
        session.apply(facts(F.sessionStart))
        #expect(session.mcpServers.isEmpty)
    }
}

@Suite struct ClaudeMCPConfigTests {
    @Test func readsNamesAndTransportsAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mcp-config-\(UUID().uuidString)")
        let cwd = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claudeJSON = folder.appending(path: ".claude.json")
        try F.claudeJSON(cwd: cwd.path).write(to: claudeJSON, atomically: true, encoding: .utf8)
        try F.mcpJSON.write(to: cwd.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)

        let declared = ClaudeMCPConfig.read(claudeJSON: claudeJSON, cwd: cwd.path)
        let byName = Dictionary(uniqueKeysWithValues: declared.map { ($0.name, $0) })
        // server-b is disabled for this folder; server-other belongs to another; .mcp.json's rejected and
        // unapproved servers never run.
        #expect(byName.keys.sorted() == ["server-a", "server-local", "server-project", "shadowed"])
        #expect(byName["server-a"] == .init(name: "server-a", source: .user, transport: "http"))
        #expect(byName["server-local"] == .init(name: "server-local", source: .local, transport: "sse"))
        #expect(byName["server-project"] == .init(name: "server-project", source: .project, transport: "stdio"))
        #expect(byName["shadowed"]?.source == .local, "the narrower scope wins")
        // The declarations hold no secret: nothing but these three fields exists to hold one.
        #expect(!String(describing: declared).contains("SECRET"))
    }

    @Test func missingOrBrokenFilesDeclareNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString).json")
        #expect(ClaudeMCPConfig.read(claudeJSON: missing, cwd: "/nowhere").isEmpty)
        let broken = FileManager.default.temporaryDirectory.appending(path: "broken-\(UUID().uuidString).json")
        try "{not json".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(ClaudeMCPConfig.read(claudeJSON: broken, cwd: "/nowhere").isEmpty)
    }
}

@Suite struct ClaudeCompactionsTests {
    @Test func autoCompactionRunsFromPreCompactToItsBoundary() throws {
        var session = ClaudeSession()
        session.apply(facts(F.preCompactAuto, at: Date(timeIntervalSince1970: 2000)))
        #expect(session.compactions.isRunning)
        #expect(session.compactions.running?.trigger == "auto")
        #expect(session.compactions.running?.since == Date(timeIntervalSince1970: 2000))
        // Another hook meanwhile does not move it.
        let running = session.compactions
        session.apply(facts(F.mcpToolCall, at: Date(timeIntervalSince1970: 2001)))
        #expect(session.compactions == running)
        session.apply(records(ClaudeNativeFixtures.compactBoundary))
        #expect(!session.compactions.isRunning)
        let entry = try #require(session.compactions.last)
        #expect(entry.isAutomatic && entry.preTokens == 167_000 && entry.postTokens == 21_000 && entry.durationMs == 41_000)
        session.apply(facts(F.postCompactAuto))
        #expect(session.compactions.count == 1, "the hook does not add a second one")
    }

    @Test func postCompactAloneEndsIt() {
        var compactions = ClaudeCompactions()
        compactions.apply(facts(F.preCompactAuto))
        compactions.apply(facts(F.postCompactAuto))
        #expect(!compactions.isRunning)
        #expect(compactions.count == 0, "the list is the transcript's")
    }

    @Test func aPreCompactWithoutItsEndIsClosedByTheTurnEnding() {
        var compactions = ClaudeCompactions()
        compactions.apply(facts(F.preCompactAuto))
        compactions.apply(facts(#"{"hook_event_name":"Stop","session_id":"<id>"}"#))
        #expect(!compactions.isRunning)
        compactions.apply(facts(F.preCompactAuto))
        compactions.apply(facts(#"{"hook_event_name":"SessionStart","source":"compact"}"#))
        #expect(!compactions.isRunning)
        compactions.apply(facts(F.preCompactAuto))
        compactions.apply(facts(#"{"hook_event_name":"PreCompact","trigger":"auto","agent_id":"a1"}"#))
        compactions.apply(facts(#"{"hook_event_name":"Stop","agent_id":"a1"}"#))
        #expect(compactions.isRunning, "a sub-agent's hooks are not the session's")
    }

    @Test func manualAndAutoAreListedOnceEachEvenReadTwice() throws {
        var compactions = ClaudeCompactions()
        let both = records(ClaudeNativeFixtures.compactBoundary, F.manualCompactBoundary)
        compactions.apply(both)
        compactions.apply(both)
        #expect(compactions.count == 2)
        #expect(compactions.entries.map(\.trigger) == ["auto", "manual"])
        #expect(compactions.last?.preTokens == 98_000 && compactions.last?.postTokens == 15_000)
    }

    @Test func theHeadlineSaysCompacting() {
        let activity = ThreadActivity()
        #expect(ThreadActivityHeadline.make(activity, state: .running, compacting: true)?.text == "Compacting…")
        #expect(ThreadActivityHeadline.make(activity, state: .idle, compacting: true)?.text == "Compacting…")
        #expect(ThreadActivityHeadline.make(activity, state: .idle, compacting: true)?.since == nil)
        #expect(ThreadActivityHeadline.make(activity, state: .exited, compacting: true) == nil)
        #expect(ThreadActivityHeadline.make(activity, state: .running)?.text == "Working…")
    }
}

@Suite struct ClaudeSessionModelTests {
    @Test func startsOnTheSessionStartModelAndFollowsSwitches() {
        var session = ClaudeSession()
        session.apply(facts(F.sessionStart))
        #expect(session.model.id == "claude-opus-5-5")
        #expect(session.model.previous == nil)
        session.apply(facts(F.modelSwitch))
        #expect(session.model.id == "claude-fable-5-1")
        #expect(session.model.previous == "claude-opus-5-5")
        // A resume says the model again, and keeps what the switch said came before.
        session.apply(facts(#"{"hook_event_name":"SessionStart","source":"resume","model":"claude-fable-5-1"}"#))
        #expect(session.model.id == "claude-fable-5-1" && session.model.previous == "claude-opus-5-5")
        session.apply(facts(#"{"hook_event_name":"PostModelSwitch","agent_id":"a1","to_model":"claude-haiku-5-5"}"#))
        #expect(session.model.id == "claude-fable-5-1", "a sub-agent's model is its own")
    }

    @Test func theModeFollowsHooksAndReads() {
        var session = ClaudeSession()
        session.apply(facts(F.enterPlanMode))
        #expect(session.permissionMode == "plan")
        #expect(ClaudePermissionMode.label(session.permissionMode) == "Plan mode")
        session.apply(facts(F.mcpToolCall))
        #expect(session.permissionMode == "auto")
        #expect(ClaudePermissionMode.label("default") == nil)
        #expect(ClaudePermissionMode.label("bypassPermissions") == "Bypassing permissions")
        #expect(ClaudePermissionMode.short("bypassPermissions") == "bypass")
        #expect(ClaudePermissionMode.short("acceptEdits") == "accept edits")
        #expect(ClaudePermissionMode.label("someFutureMode") == "someFutureMode")
    }
}

@Suite struct ClaudeSessionPullRequestsTests {
    @Test func aCreatedPullRequestIsReportedOnceThenItsMerge() throws {
        var session = ClaudeSession()
        let empty = session.pullRequests
        session.apply(facts(F.prCreated))
        let created = session.pullRequests
        let first = try #require(created.changes(since: empty).first)
        #expect(first.number == 57 && first.action == "created" && first.repository == "<owner>/<repo>")
        // The transcript's `pr-link` for the same pull request is the same news.
        session.apply(records(F.prLink57))
        #expect(session.pullRequests.entries.count == 1)
        #expect(session.pullRequests.changes(since: created).isEmpty)
        #expect(session.pullRequests.entries.first?.action == "created")
        let linked = session.pullRequests
        session.apply(facts(F.prMerged))
        #expect(session.pullRequests.changes(since: linked).map(\.action) == ["merged"])
    }

    @Test func aPushWithoutPullRequestAndOtherToolsSayNothing() {
        var pullRequests = ClaudeSessionPullRequests()
        pullRequests.apply(facts(F.pushOnly))
        pullRequests.apply(facts(F.mcpToolCall))
        pullRequests.apply(facts(#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"plain text"}"#))
        #expect(pullRequests.entries.isEmpty)
    }

    @Test func aPRLinkAloneIsReported() {
        var pullRequests = ClaudeSessionPullRequests()
        pullRequests.apply(records(ClaudeNativeFixtures.prLink))
        #expect(pullRequests.entries.map(\.number) == [42])
        #expect(pullRequests.entries.first?.action == nil)
    }
}

@Suite struct ClaudeSessionSummaryTests {
    @Test func nothingKnownIsNoSummary() {
        #expect(ClaudeSessionSummary.make(ClaudeSession()) == nil)
    }

    @Test func carriesModeModelCompactionsAndServersInTrouble() throws {
        var session = ClaudeSession()
        session.apply(facts(F.sessionStart))
        session.apply(facts(F.enterPlanMode))
        session.apply(records(F.mcpAllPending, F.mcpSettled, ClaudeNativeFixtures.compactBoundary))
        session.apply(facts(F.preCompactAuto))
        let summary = try #require(ClaudeSessionSummary.make(session))
        #expect(summary.permissionMode == "auto")
        #expect(summary.model == "claude-opus-5-5")
        #expect(summary.compacting == true)
        #expect(summary.compactions == 1)
        #expect(summary.lastCompaction?.trigger == "auto" && summary.lastCompaction?.postTokens == 21_000)
        #expect(summary.mcpServers?.map(\.name) == ["plugin:design:figma", "server-b"])
        #expect(summary.mcpServers?.last?.code == "CONNECTION_CLOSED")
        #expect(summary.notes == ["compacting", "1 compaction", "MCP failed: server-b", "MCP needs auth: plugin:design:figma"])

        // On the wire, and from a build before the field.
        let thread = ThreadSummary(id: "aaaaaaaaaaa1", title: "fix", driver: "claude-code", model: "opus", scope: "acme",
                                   scopeSlug: "acme", task: nil, cwd: "/w", state: "running", alive: true, openedBy: "user",
                                   depth: 0, activity: "Edit a.swift · 2m ago", session: summary)
        let decoded = try ControlProtocol.makeDecoder().decode(ListResult.self,
                                                                from: ControlProtocol.makeEncoder().encode(ListResult(threads: [thread])))
        #expect(decoded.threads.first?.session == summary)
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        older["session"] = nil
        #expect(try JSONDecoder().decode(ThreadSummary.self, from: JSONSerialization.data(withJSONObject: older)).session == nil)

        // In the table: the model it runs on now, the mode, and the trouble after the activity.
        let lines = CLIRenderer.text(.list(ListResult(threads: [thread]))).split(separator: "\n")
        #expect(lines.first?.contains("MODEL            MODE") == true)
        #expect(lines.last?.contains("claude-opus-5-5  auto") == true)
        #expect(lines.last?.hasSuffix("Edit a.swift · 2m ago · compacting · 1 compaction · MCP failed: server-b · MCP needs auth: plugin:design:figma") == true)
    }

    @Test func aLongFailureMessageIsBounded() throws {
        var session = ClaudeSession()
        let long = String(repeating: "x", count: 1000)
        session.apply([.mcpServers(ClaudeMCPServerReport(pending: [], failed: [.init(name: "s", error: long, code: "E")], needsAuth: []))])
        let error = try #require(ClaudeSessionSummary.make(session)?.mcpServers?.first?.error)
        #expect(error.count == ClaudeSessionSummary.errorLimit)
    }
}
