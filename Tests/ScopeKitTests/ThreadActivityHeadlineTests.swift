import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters
@testable import ScopeControl

/// `ThreadActivityHeadline`: the activity line of a detailed sidebar row.
@Suite struct ThreadActivityHeadlineTests {
    static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    static func working(_ name: String, _ target: String?) -> ThreadActivity {
        ThreadActivity(lastTool: .init(name: name, target: target, at: at(5)), turnStartedAt: at(1), turnTools: 1)
    }

    static func line(_ activity: ThreadActivity, _ state: ThreadState,
                     finished: FinishedThreadLine = .elapsed) -> ThreadActivityHeadline? {
        ThreadActivityHeadline.make(activity, state: state, finished: finished)
    }

    // MARK: Running

    @Test("each tool kind reads as what the agent is doing", arguments: [
        ("Edit", "/w/Sources/ScopeTasks/TaskTopic.swift", "Editing TaskTopic.swift"),
        ("MultiEdit", "/w/a.swift", "Editing a.swift"),
        ("Write", "/w/docs/NEW.md", "Writing NEW.md"),
        ("Read", "/w/Sources/ScopeControl/MCPBridge.swift", "Reading MCPBridge.swift"),
        ("NotebookEdit", "/w/n.ipynb", "Editing n.ipynb"),
        ("Bash", "swift test --filter SlugTests", "Running swift test --filter SlugTests"),
        ("Bash", "cd /w/scope && cd Sources && swift build", "Running swift build"),
        ("Grep", "topic", "Searching \"topic\""),
        ("Glob", "**/*.swift", "Looking for \"**/*.swift\""),
        ("WebFetch", "https://docs.github.com/en/rest", "Fetching docs.github.com"),
        ("WebSearch", "swift testing arguments", "Searching the web for \"swift testing arguments\""),
        ("Task", "Survey the hooks", "Delegating: Survey the hooks"),
        ("Skill", "scope", "Using the skill scope"),
        ("TodoWrite", nil, "Updating its plan"),
        ("mcp__scope__scope_thread_wait", "3f9a", "Using scope_thread_wait"),
        ("FancyNewTool", "whatever", "Using FancyNewTool"),
    ] as [(String, String?, String)])
    func running(tool: String, target: String?, text: String) {
        #expect(Self.line(Self.working(tool, target), .running)?.text == text)
    }

    @Test("the help carries what the line shortened, and only that")
    func detail() {
        #expect(Self.line(Self.working("Edit", "/w/a/App.swift"), .running)?.detail == "/w/a/App.swift")
        #expect(Self.line(Self.working("Bash", "cd /w && make"), .running)?.detail == "cd /w && make")
        #expect(Self.line(Self.working("Bash", "make"), .running)?.detail == nil)
        #expect(Self.line(Self.working("Grep", "topic"), .running)?.detail == nil)
        #expect(Self.line(Self.working("WebFetch", "https://a.dev/x"), .running)?.detail == "https://a.dev/x")
    }

    @Test("running carries no time: it is happening now")
    func runningHasNoTime() {
        #expect(Self.line(Self.working("Edit", "/w/a.swift"), .running)?.since == nil)
    }

    @Test("a tool from the previous turn is not what the agent is doing now")
    func staleTool() {
        let activity = ThreadActivity(lastTool: .init(name: "Edit", target: "/w/a.swift", at: Self.at(0)),
                                      turnStartedAt: Self.at(10))
        #expect(Self.line(activity, .running)?.text == "Working…")
        #expect(Self.line(ThreadActivity(), .running)?.text == "Working…")
    }

    @Test("an empty target is no target")
    func emptyTarget() {
        #expect(Self.line(Self.working("Read", ""), .running)?.text == "Reading")
    }

    // MARK: Waiting

    @Test("a permission reads as what the agent asks to do")
    func permission() {
        var activity = ThreadActivity()
        activity.pendingRequest = .init(name: "Bash", target: "swift test", at: Self.at(3))
        #expect(Self.line(activity, .waiting(reason: .permission))?.text == "Asks to run swift test")
        activity.pendingRequest = .init(name: "Edit", target: "/w/Sources/App.swift", at: Self.at(3))
        let edit = Self.line(activity, .waiting(reason: .permission))
        #expect(edit?.text == "Asks to edit App.swift")
        #expect(edit?.detail == "/w/Sources/App.swift")
    }

    @Test("a question reads as itself")
    func question() {
        var activity = ThreadActivity()
        activity.pendingRequest = .init(name: "AskUserQuestion", target: "Which suite first?", at: Self.at(3))
        #expect(Self.line(activity, .waiting(reason: .input))?.text == "Which suite first?")
        activity.pendingRequest = .init(name: "AskUserQuestion", target: nil, at: Self.at(3))
        #expect(Self.line(activity, .waiting(reason: .input))?.text == "Asking you a question")
        activity.pendingRequest = .init(name: "ExitPlanMode", target: "## Plan", at: Self.at(3))
        #expect(Self.line(activity, .waiting(reason: .input))?.text == "Proposing a plan")
    }

    @Test("a question asked in prose is the reply's last line")
    func proseQuestion() {
        var activity = ThreadActivity()
        activity.lastReply = AgentReply(text: "I looked at both.\n\nShould I keep the old flag?\n", at: Self.at(4))
        #expect(Self.line(activity, .waiting(reason: .input))?.text == "Should I keep the old flag?")
        #expect(Self.line(ThreadActivity(), .waiting(reason: .input))?.text == "Waiting for your answer")
        #expect(Self.line(ThreadActivity(), .waiting(reason: .permission))?.text == "Waiting for your permission")
    }

    // MARK: Folded from events

    static func event(_ kind: HookEvent.Kind, _ seconds: TimeInterval, _ payload: [String: String] = [:]) -> AdapterEvent {
        AdapterEvent(threadID: ThreadID(rawValue: "3f9a2c17be04")!, kind: kind, payload: payload, raw: nil,
                     receivedAt: at(seconds))
    }

    @Test("the request is kept through the notification that follows it, and dropped once the agent goes on")
    func pendingRequestLifecycle() {
        var activity = ThreadActivity()
        activity = activity.apply(Self.event(.turnStarted, 0))
        activity = activity.apply(Self.event(.permissionRequested, 1,
                                             [HookEvent.toolKey: "Bash", HookEvent.targetKey: "make"]))
        activity = activity.apply(Self.event(.permissionRequested, 2, [HookEvent.viaKey: HookEvent.viaNotification]))
        #expect(activity.pendingRequest == .init(name: "Bash", target: "make", at: Self.at(1)))
        activity = activity.apply(Self.event(.turnStarted, 3, [HookEvent.toolKey: "Bash", HookEvent.targetKey: "make"]))
        #expect(activity.pendingRequest == nil)
    }

    @Test("an activity saved before the request was kept still decodes")
    func decodesWithoutRequest() throws {
        let json = #"{"version":1,"turnTools":0,"turns":[]}"#
        let activity = try JSONDecoder().decode(ThreadActivity.self, from: Data(json.utf8))
        #expect(activity.pendingRequest == nil)
    }

    // MARK: Over

    static func finished(_ outcome: ThreadActivity.Turn.Outcome, error: String? = nil,
                         reply: String? = nil) -> ThreadActivity {
        ThreadActivity(turns: [.init(startedAt: at(0), endedAt: at(60), outcome: outcome, error: error)],
                       lastReply: reply.map { AgentReply(text: $0, at: at(60)) })
    }

    @Test("a finished turn says so, with its time; the reply's first line goes to the help")
    func finishedTurn() {
        let line = Self.line(Self.finished(.ended, reply: "\nRenamed the flag.\nDetails…"), .done)
        #expect(line == ThreadActivityHeadline(text: "Finished", detail: "Renamed the flag.", since: Self.at(60),
                                               reply: "Renamed the flag."))
        // Read since: the row still says when it finished.
        #expect(Self.line(Self.finished(.ended), .idle)?.text == "Finished")
    }

    @Test("the preference can show the reply's first line instead")
    func replyPreference() {
        let line = Self.line(Self.finished(.ended, reply: "Renamed the flag.\nDetails…"), .done, finished: .reply)
        #expect(line?.text == "Renamed the flag.")
        #expect(line?.since == Self.at(60))
        // No reply: back to "Finished".
        #expect(Self.line(Self.finished(.ended), .done, finished: .reply)?.text == "Finished")
    }

    @Test("a reply from an earlier turn is not this one's")
    func staleReply() {
        var activity = Self.finished(.ended)
        activity.lastReply = AgentReply(text: "Old answer", at: Self.at(-30))
        #expect(Self.line(activity, .done, finished: .reply)?.text == "Finished")
    }

    @Test("other endings", arguments: [
        (ThreadActivity.Turn.Outcome.failed, "rate_limit", ThreadState.failed, "Failed (rate_limit)"),
        (.failed, nil, .failed, "Failed"),
        (.interrupted, nil, .idle, "Interrupted"),
        (.exited, nil, .idle, "Stopped mid-turn"),
    ] as [(ThreadActivity.Turn.Outcome, String?, ThreadState, String)])
    func endings(outcome: ThreadActivity.Turn.Outcome, error: String?, state: ThreadState, text: String) {
        #expect(Self.line(Self.finished(outcome, error: error), state)?.text == text)
    }

    @Test("nothing better to say: the row keeps its own caption")
    func nothing() {
        #expect(Self.line(ThreadActivity(), .idle) == nil)
        #expect(Self.line(Self.finished(.ended), .exited) == nil)
        #expect(Self.line(Self.finished(.permissionRequested), .idle) == nil)
    }

    // MARK: What a Claude Code session asks

    static func asked(_ payloads: [String]) -> ClaudePendingRequest? {
        var pending = ClaudePendingRequests()
        for payload in payloads {
            guard let body = JSONValue(json: payload) else { continue }
            pending.apply(ClaudeHookFacts(body: body, at: at(3)))
        }
        return pending.current
    }

    @Test("a waiting thread words what its session asks, the whole of it in the help")
    func pendingRequests() throws {
        let waiting = ThreadState.waiting(reason: .permission)
        let bash = ThreadActivityHeadline.make(ThreadActivity(), state: waiting,
                                               pending: Self.asked(Array(ClaudePendingFixtures.bash[2...3])))
        #expect(bash?.text == "Asks to run echo probe hello")
        let mcp = ThreadActivityHeadline.make(ThreadActivity(), state: waiting,
                                              pending: Self.asked(Array(ClaudePendingFixtures.mcp[4...5])))
        #expect(mcp?.text == "Asks to use probe_echo on probe")
        let write = ThreadActivityHeadline.make(ThreadActivity(), state: waiting,
                                                pending: Self.asked(Array(ClaudePendingFixtures.write[2...3])))
        #expect(write?.text == "Asks to write notes.txt")
        #expect(write?.detail == "/w/notes.txt")
        let edit = ThreadActivityHeadline.make(ThreadActivity(), state: waiting, pending: Self.asked(ClaudePendingFixtures.edit))
        #expect(edit?.text == "Asks to edit existing.txt")
        let input = ThreadState.waiting(reason: .input)
        let two = ThreadActivityHeadline.make(ThreadActivity(), state: input,
                                              pending: Self.asked([ClaudePendingFixtures.twoQuestions]))
        #expect(two?.text == "Which color? (+1 more)")
        #expect(two?.detail == "Which color?\nWhich size?")
        let form = ThreadActivityHeadline.make(ThreadActivity(), state: input,
                                               pending: Self.asked(Array(ClaudePendingFixtures.elicitation[4...5])))
        #expect(form?.text == "probe asks: Pick a deployment tier")
        let plan = ThreadActivityHeadline.make(ThreadActivity(), state: input, pending: Self.asked(ClaudePendingFixtures.plan))
        #expect(plan?.text == "Plan: Create `hello.txt` in the project root (`/w`).")
    }

    @Test("a command of several lines shows its first, and the help keeps it whole")
    func multilineCommand() throws {
        let payload = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"cd /w && git add -A\ngit commit -m x"}}"#
        let line = ThreadActivityHeadline.make(ThreadActivity(), state: .waiting(reason: .permission),
                                               pending: Self.asked([payload, ClaudePendingFixtures.permissionPrompt]))
        #expect(line?.text == "Asks to run git add -A")
        #expect(line?.detail == "cd /w && git add -A\ngit commit -m x")
    }

    @Test("what the session asks only words a waiting thread")
    func pendingOnlyWhileWaiting() {
        let request = Self.asked(Array(ClaudePendingFixtures.bash[2...3]))
        #expect(ThreadActivityHeadline.make(Self.working("Bash", "make"), state: .running, pending: request)?.text == "Running make")
    }
}
