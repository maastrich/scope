import Foundation
@testable import ScopeAdapters
import ScopeCore
import Testing
@testable import ScopeDrivers

/// `ClaudePendingRequests` over real hook sequences (`ClaudePendingFixtures`, `ClaudePermissionReplayTests`), each
/// payload kept only if the `claude-hooks` adapter installs its hook, the way Claude Code would deliver it.
@Suite struct ClaudePendingRequestsTests {
    /// `true` when the settings file Scope writes would deliver `payload` to `scope-hook` (matchers read as Claude Code
    /// does: an alternation over the tool name or the notification type).
    static func installed(_ body: JSONValue) -> Bool {
        let hook = body["hook_event_name"]?.string ?? ""
        let subject = body["tool_name"]?.string ?? body["notification_type"]?.string ?? ""
        return ClaudeHooksAdapter.entries.contains { entry in
            entry.event == hook && (entry.matcher.map { $0.split(separator: "|").contains { $0 == subject } } ?? true)
        }
    }

    /// The pending requests after each delivered payload.
    static func replay(_ payloads: [String], from start: ClaudePendingRequests = ClaudePendingRequests())
        -> [ClaudePendingRequests] {
        var pending = start
        var steps: [ClaudePendingRequests] = []
        for (index, payload) in payloads.enumerated() {
            guard let body = JSONValue(json: payload), installed(body) else { continue }
            pending.apply(ClaudeHookFacts(body: body, at: Date(timeIntervalSince1970: 1000 + Double(index))))
            steps.append(pending)
        }
        return steps
    }

    static func final(_ payloads: [String]) -> ClaudePendingRequests {
        replay(payloads).last ?? ClaudePendingRequests()
    }

    @Test("a Bash permission shows its whole command once the dialog is up, and goes when the tool has run")
    func bashPermission() throws {
        let steps = Self.replay(ClaudePendingFixtures.bash)
        // prompt, PermissionRequest, permission_prompt, PostToolUse, Stop (PreToolUse of Bash is not installed).
        #expect(steps.count == 5)
        #expect(steps[1].requests.count == 1)
        #expect(steps[1].current == nil, "described, not yet shown: another hook may still answer")
        let shown = try #require(steps[2].current)
        #expect(shown.kind == .permission)
        #expect(shown.tool == "Bash")
        #expect(shown.command == "echo probe hello")
        #expect(shown.summary == "Print probe hello")
        #expect(shown.headline == "echo probe hello")
        #expect(shown.suggestions.isEmpty)
        #expect(steps[2].waitReason == .permission)
        #expect(steps[3].requests.isEmpty)
    }

    @Test("a Write permission names the file, the kind of change and the rule offered")
    func writePermission() throws {
        let pending = Self.final(ClaudePendingFixtures.write)
        let request = try #require(pending.current)
        #expect(request.filePath == "/w/notes.txt")
        #expect(request.edit == "create or overwrite")
        #expect(request.headline == "Write notes.txt")
        #expect(request.suggestions == ["switch to acceptEdits (session)"])
    }

    @Test("an Edit permission names the file and an edit of every occurrence")
    func editPermission() throws {
        let request = try #require(Self.final(ClaudePendingFixtures.edit).current)
        #expect(request.tool == "Edit")
        #expect(request.filePath == "/w/existing.txt")
        #expect(request.edit == "edit (every occurrence)")
        #expect(request.headline == "Edit existing.txt")
        #expect(request.suggestions == ["switch to acceptEdits (session)"])
    }

    @Test("a No in the dialog fires no hook: the transcript's end of turn clears it")
    func deniedClearsAtTurnEnd() {
        var pending = Self.final(ClaudePendingFixtures.write)
        #expect(pending.current != nil)
        pending.apply([.turnDuration(ClaudeTurnDuration(durationMs: 1000, pendingBackgroundAgents: 0, at: nil))])
        #expect(pending.requests.isEmpty)
    }

    @Test("a turn's end replayed from the transcript's start does not clear what is asked now")
    func replayedTurnEnd() throws {
        var pending = Self.final(ClaudePendingFixtures.write)
        let asked = try #require(pending.current).askedAt
        pending.apply([.turnDuration(ClaudeTurnDuration(durationMs: 1000, pendingBackgroundAgents: 0,
                                                        at: asked.addingTimeInterval(-60)))])
        #expect(pending.current != nil)
        pending.apply([.turnDuration(ClaudeTurnDuration(durationMs: 1000, pendingBackgroundAgents: 0,
                                                        at: asked.addingTimeInterval(2)))])
        #expect(pending.requests.isEmpty)
    }

    @Test("an MCP permission names its tool, its server and the rule offered")
    func mcpPermission() throws {
        let steps = Self.replay(ClaudePendingFixtures.mcp)
        let request = try #require(steps.compactMap(\.current).first)
        #expect(request.mcpServer == "probe")
        #expect(request.mcpTool == "probe_echo")
        #expect(request.headline == "probe_echo on probe")
        #expect(request.suggestions == ["allow mcp__probe__probe_echo (local settings)"])
        #expect(steps.last?.requests.isEmpty == true)
    }

    @Test("a question is shown from its PreToolUse with its header and options, once, until it is answered")
    func singleQuestion() throws {
        let steps = Self.replay(ClaudePendingFixtures.question)
        // prompt, PreToolUse, PermissionRequest, permission_prompt, PostToolUse, Stop.
        let asked = try #require(steps[1].current)
        #expect(asked.kind == .question)
        #expect(asked.toolUseID == "toolu_01XM")
        #expect(asked.questions == [ClaudePendingRequest.Question(
            question: "Which color should the probe use?", header: "Color", multiSelect: false,
            options: [.init(label: "Red", description: "Warm tone"), .init(label: "Blue", description: "Cool tone")])])
        #expect(asked.headline == "Which color should the probe use?")
        #expect(steps[1].waitReason == .input)
        // The question tool's own PermissionRequest and permission_prompt add nothing.
        #expect(steps[3].requests == steps[1].requests)
        #expect(steps[4].requests.isEmpty)
    }

    @Test("a multiple-choice question and a two-question call keep every question and option")
    func multiSelectAndSeveral() throws {
        let multi = try #require(Self.final([ClaudePendingFixtures.multiSelect]).current)
        #expect(multi.questions.first?.multiSelect == true)
        #expect(multi.questions.first?.options.map(\.label) == ["Lint", "Tests", "Build"])
        let two = try #require(Self.final([ClaudePendingFixtures.twoQuestions]).current)
        #expect(two.questions.map(\.header) == ["Color", "Size"])
        #expect(two.headline == "Which color? (+1 more)")
    }

    @Test("a plan keeps its text and its file, and reads from its first bullet")
    func plan() throws {
        let request = try #require(Self.final(ClaudePendingFixtures.plan).current)
        #expect(request.kind == .plan)
        #expect(request.plan?.hasPrefix("## Plan") == true)
        #expect(request.planFilePath == "/home/.claude/plans/plan-add-a-file.md")
        #expect(request.headline == "Plan: Create `hello.txt` in the project root (`/w`).")
        #expect(Self.final(ClaudePendingFixtures.plan).requests.count == 1)
    }

    @Test("an elicitation shows its server, message and fields from its notification, and goes with its result")
    func elicitation() throws {
        let steps = Self.replay(ClaudePendingFixtures.elicitation)
        // prompt, PermissionRequest, permission_prompt, Elicitation, elicitation_dialog, ElicitationResult, PostToolUse, Stop
        #expect(steps[2].current?.kind == .permission)
        #expect(steps[3].requests.map(\.kind) == [.elicitation], "the server's tool runs: its permission was given")
        #expect(steps[3].current == nil)
        let form = try #require(steps[4].current)
        #expect(form.mcpServer == "probe")
        #expect(form.message == "Pick a deployment tier")
        #expect(form.mode == "form")
        #expect(form.fields == ["tier"])
        #expect(form.headline == "probe: Pick a deployment tier")
        #expect(steps[4].waitReason == .input)
        #expect(steps[5].requests.isEmpty)
    }

    @Test("an elicitation notification without its hook still says a form is up")
    func elicitationWithoutHook() throws {
        let request = try #require(Self.final([ClaudePendingFixtures.elicitation[5]]).current)
        #expect(request.kind == .elicitation)
        #expect(request.message == nil)
    }

    @Test("a permission decided elsewhere is never shown: auto mode, another PermissionRequest hook")
    func decidedElsewhere() {
        for payloads in [ClaudePermissionReplayTests.classifierAllowed, ClaudePermissionReplayTests.hookAllowed] {
            let steps = Self.replay(payloads)
            #expect(steps.allSatisfy { $0.current == nil })
            #expect(steps.last?.requests.isEmpty == true)
        }
    }

    @Test("a permission the classifier denies goes with PermissionDenied")
    func classifierDenied() {
        let request = #"{"session_id":"s1","hook_event_name":"PermissionRequest","permission_mode":"auto","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let denied = #"{"session_id":"s1","hook_event_name":"PermissionDenied","permission_mode":"auto","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"reason":"<text>"}"#
        #expect(Self.replay([request, denied]).last?.requests.isEmpty == true)
    }

    @Test("two stacked permissions are asked in order, the second up once the first has run")
    func stacked() throws {
        let steps = Self.replay(ClaudePendingFixtures.stacked)
        // prompt, PR alpha, PR beta, prompt ×2, PostToolUse alpha, prompt, PostToolUse beta, Stop
        #expect(steps[2].requests.count == 2)
        #expect(steps[2].current == nil)
        #expect(steps[4].shown.map(\.command) == ["echo probe alpha", "echo probe beta"])
        #expect(steps[4].current?.command == "echo probe alpha")
        #expect(steps[5].current?.command == "echo probe beta")
        #expect(steps[5].waitReason == .permission, "still waiting on the second one")
        #expect(steps[6].current?.command == "echo probe beta")
        #expect(steps[7].requests.isEmpty)
    }

    @Test("the first of two stacked permissions answered at a key: its tool report leaves the second asked")
    func stackedAnsweredByKey() {
        var pending = Self.replay(Array(ClaudePendingFixtures.stacked.prefix(7))).last!
        #expect(pending.current?.command == "echo probe alpha")
        let key = pending.userTyped([0x31])
        #expect(key == .approved)
        #expect(pending.current?.command == "echo probe beta")
        pending.apply(ClaudeHookFacts(body: JSONValue(json: ClaudePendingFixtures.stacked[7])!, at: .now))
        #expect(pending.current?.command == "echo probe beta")
        #expect(pending.waitReason == .permission)
    }

    @Test("a tool report whose input was clamped differently still finds its permission by tool")
    func fallbackMatch() {
        let request = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make all"}}"#
        let ran = #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"make al…"},"tool_use_id":"toolu_9"}"#
        #expect(Self.replay([request, ClaudePendingFixtures.permissionPrompt, ran]).last?.requests.isEmpty == true)
    }

    @Test("the user's key in the dialog decides it: 1 approves, another digit, Return or Esc answers")
    func keystrokes() {
        var pending = Self.final(ClaudePendingFixtures.bash.dropLast(2).map { $0 })
        #expect(pending.current != nil)
        let r1 = pending.userTyped(Array("a".utf8))
        #expect(r1 == .none)
        let r2 = pending.userTyped(Array("12".utf8))
        #expect(r2 == .none, "a paste is not a key")
        let r3 = pending.userTyped([0x31])
        #expect(r3 == .approved)
        #expect(pending.requests.isEmpty)

        for key: UInt8 in [0x32, 0x0d, 0x1b] {
            var again = Self.final(ClaudePendingFixtures.bash.dropLast(2).map { $0 })
            let r4 = again.userTyped([key])
            #expect(r4 == .answered)
            #expect(again.requests.isEmpty)
        }
    }

    @Test("a single-choice question goes with its option's digit; a multiple choice waits for its tool")
    func questionKeystrokes() {
        var single = Self.final(Array(ClaudePendingFixtures.question.prefix(2)))
        let r5 = single.userTyped([0x32])
        #expect(r5 == .answered)
        #expect(single.requests.isEmpty)
        var multi = Self.final([ClaudePendingFixtures.multiSelect])
        let r6 = multi.userTyped([0x31])
        #expect(r6 == .none)
        #expect(multi.current != nil)
        let r7 = multi.userTyped([0x1b])
        #expect(r7 == .answered)
    }

    @Test("a permission described but not up yet can be confirmed by what the session says it waits for")
    func confirmFromAgents() {
        var pending = Self.replay(Array(ClaudePendingFixtures.bash.prefix(3))).last!
        #expect(pending.current == nil)
        let r8 = pending.confirmPermission()
        #expect(r8 != nil && r8 == pending.current?.id)
        #expect(pending.current?.command == "echo probe hello")
        let r9 = pending.confirmPermission()
        #expect(r9 == nil)
    }

    @Test("a fresh session forgets what the last one asked; a resume keeps it")
    func freshSession() {
        var session = ClaudeSession()
        for payload in ClaudePendingFixtures.write {
            guard let body = JSONValue(json: payload), Self.installed(body) else { continue }
            session.apply(ClaudeHookFacts(body: body, at: .now))
        }
        #expect(session.pending.current != nil)
        let resume = JSONValue(json: #"{"hook_event_name":"SessionStart","session_id":"s1","source":"resume"}"#)!
        session.apply(ClaudeHookFacts(body: resume, at: .now))
        #expect(session.pending.current != nil)
        let clear = JSONValue(json: #"{"hook_event_name":"SessionStart","session_id":"s2","source":"clear"}"#)!
        session.apply(ClaudeHookFacts(body: clear, at: .now))
        #expect(session.pending.requests.isEmpty)
    }

    @Test("a question answered shows in the transcript as its call: that clears it too")
    func transcriptClearsQuestion() {
        var pending = Self.final(Array(ClaudePendingFixtures.question.prefix(2)))
        let call = ClaudeToolCall(id: "toolu_01XM", name: "AskUserQuestion", input: .object([:]), result: nil,
                                  isError: false, startedAt: nil, endedAt: nil)
        pending.apply([.toolCall(call)])
        #expect(pending.requests.isEmpty)
    }

    @Test("unknown events, odd shapes and missing fields are ignored")
    func tolerant() {
        let odd = [
            #"{"hook_event_name":"PermissionRequest"}"#,
            #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":"not an object"}"#,
            #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"no question"},7,{"question":"Q?","options":[{"description":"no label"},{"label":"A"}]}]}}"#,
            #"{"hook_event_name":"Notification","notification_type":"something_new"}"#,
            #"{"hook_event_name":"Elicitation"}"#,
            #"{"hook_event_name":"SomethingNew","tool_name":"Bash"}"#,
        ]
        let pending = Self.final(odd)
        #expect(pending.requests.map(\.kind) == [.permission, .question, .elicitation])
        let question = pending.requests.first { $0.kind == .question }
        #expect(question?.questions.map(\.question) == ["Q?"])
        #expect(question?.questions.first?.options.map(\.label) == ["A"])
        #expect(pending.requests.first?.headline == "Use Bash")
    }

    @Test("free text is bounded, ids stay stable for the same request")
    func boundedAndStable() throws {
        let long = String(repeating: "x", count: 5000)
        let payload = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#
        let first = try #require(Self.final([payload]).requests.first)
        #expect(first.command?.count == ClaudePendingRequest.textLimit)
        let second = try #require(Self.final([payload]).requests.first)
        #expect(first.id == second.id)
    }
}

/// `claude agents --json` as Claude Code 2.1.304 printed it with a permission dialog up (ids and paths replaced).
@Suite struct ClaudeAgentsReportTests {
    static let output = #"""
    [
      {"id": "cd1b1247", "cwd": "/w", "kind": "background", "startedAt": 1786799328166, "sessionId": "s-bg", "name": "<text>", "state": "blocked"},
      {"pid": 2180, "cwd": "/w", "kind": "interactive", "startedAt": 1792477900541, "sessionId": "s-idle", "name": "<text>", "status": "idle"},
      {"pid": 64314, "cwd": "/w", "kind": "interactive", "startedAt": 1792494441244, "sessionId": "s-asks", "name": "<text>", "status": "waiting", "waitingFor": "permission prompt"},
      {"pid": 7, "kind": "interactive", "sessionId": "s-input", "status": "waiting", "waitingFor": "input needed"},
      {"pid": 8, "status": "busy"}
    ]
    """#

    @Test("only a session waiting on a permission dialog counts")
    func waitsOnPermission() {
        let report = ClaudeAgentsReport(json: Data(Self.output.utf8))
        #expect(report.sessions.map(\.sessionID) == ["s-bg", "s-idle", "s-asks", "s-input"])
        #expect(report.sessions[2].pid == 64314)
        #expect(report.waitsOnPermission(sessionID: "s-asks"))
        #expect(!report.waitsOnPermission(sessionID: "s-input"))
        #expect(!report.waitsOnPermission(sessionID: "s-idle"))
        #expect(!report.waitsOnPermission(sessionID: "unknown"))
    }

    /// A companion's `PermissionRequest` hook allowing after three seconds (Claude Code 2.1.304): the session reads
    /// `waiting` from the moment the dialog opens, alongside that hook, then `busy` once it answered.
    @Test("a session another hook answered no longer waits on its permission")
    func decidedByAnotherHook() {
        let deciding = #"[{"pid":1,"kind":"interactive","sessionId":"s","status":"waiting","waitingFor":"permission prompt"}]"#
        let decided = #"[{"pid":1,"kind":"interactive","sessionId":"s","status":"busy"}]"#
        #expect(ClaudeAgentsReport(json: Data(deciding.utf8)).waitsOnPermission(sessionID: "s"))
        #expect(!ClaudeAgentsReport(json: Data(decided.utf8)).waitsOnPermission(sessionID: "s"))
    }

    @Test("output that is not the expected JSON reads as no session")
    func tolerant() {
        #expect(ClaudeAgentsReport(json: Data("error: unknown command".utf8)).sessions.isEmpty)
        #expect(ClaudeAgentsReport(json: Data(#"{"sessions":[]}"#.utf8)).sessions.isEmpty)
    }
}
