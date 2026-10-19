import Foundation
import ScopeAdapters
import ScopeCore
import Testing
@testable import ScopeControl

/// `thread.wait`: when a thread counts as done with what it was handed, and the call on both façades.
@Suite struct ThreadWaitTests {
    static let now = Date(timeIntervalSince1970: 10_000)

    static func settled(_ state: String, expecting ago: TimeInterval? = nil, reportsTurnStart: Bool = true,
                        starting: Bool = false) -> Bool {
        ThreadWait.isSettled(.init(state: state, expectingSince: ago.map { now.addingTimeInterval(-$0) },
                                   reportsTurnStart: reportsTurnStart, starting: starting), now: now)
    }

    @Test func aTurnThatEndedOrNeedsSomeoneIsSettled() {
        #expect(Self.settled("done"))
        #expect(Self.settled("idle"))
        #expect(Self.settled("waiting"), "a question or a permission: someone must act")
        #expect(Self.settled("failed"))
        #expect(Self.settled("exited"))
        #expect(!Self.settled("running"))
    }

    /// Just handed a prompt, the thread still reads idle (or done, from the turn before): that is not an answer.
    @Test func aPromptTheDriverHasNotReportedOnIsStillWork() {
        #expect(!Self.settled("idle", expecting: 2))
        #expect(!Self.settled("done", expecting: 2))
        #expect(Self.settled("waiting", expecting: 2), "a prompt answered by a question is settled")
        #expect(Self.settled("exited", expecting: 2))
    }

    @Test func aTurnThatNeverStartsStopsHoldingTheWait() {
        #expect(Self.settled("idle", expecting: ThreadWait.startGrace + 1))
        // Codex says nothing until its turn ends: a long turn is not a turn that never started.
        #expect(!Self.settled("idle", expecting: ThreadWait.startGrace + 1, reportsTurnStart: false))
        // A task's setup can hold the launch for minutes: the grace starts with the driver.
        #expect(!Self.settled("idle", expecting: ThreadWait.startGrace + 1, starting: true))
    }

    /// Seconds ago, as a date.
    static func ago(_ seconds: TimeInterval?) -> Date? { seconds.map { now.addingTimeInterval(-$0) } }

    static func running(reply: TimeInterval?, turnStarted: TimeInterval?, prompt: TimeInterval? = nil,
                        expecting: TimeInterval? = nil, reportsTurnStart: Bool = true, waitingFor: TimeInterval? = nil) -> Bool {
        ThreadWait.isSettled(.init(state: "running", expectingSince: ago(expecting), reportsTurnStart: reportsTurnStart,
                                   replyAt: ago(reply), turnStartedAt: ago(turnStarted), lastPromptAt: ago(prompt)),
                             now: now, waitingSince: ago(waitingFor))
    }

    /// The safety net: `running`, but the agent answered after anything that started a turn.
    @Test func runningWithAnAnswerNewerThanItsTurnIsSettled() {
        #expect(Self.running(reply: 60, turnStarted: 120))
        #expect(Self.running(reply: 60, turnStarted: nil), "nothing ever reported a start")
        #expect(!Self.running(reply: 120, turnStarted: 60), "a prompt or a tool came after the answer: a turn is on")
        #expect(!Self.running(reply: nil, turnStarted: nil))
        #expect(!Self.running(reply: 60, turnStarted: 120, prompt: 30), "handed a prompt since: the answer is for something else")
        #expect(!Self.running(reply: 60, turnStarted: 120, expecting: 30))
        // Codex: `running` comes from the prompt typed, which no hook timestamps.
        #expect(!Self.running(reply: 60, turnStarted: nil, reportsTurnStart: false))
    }

    /// An answer landing during the wait ends it, even if the state reads `running` again by the next look.
    @Test func anAnswerDuringTheWaitEndsIt() {
        #expect(Self.running(reply: 5, turnStarted: 2, waitingFor: 60))
        #expect(!Self.running(reply: 90, turnStarted: 2, waitingFor: 60), "an answer from before the wait says nothing")
        #expect(!Self.running(reply: 5, turnStarted: 2, prompt: 1, waitingFor: 60), "nor one older than the last prompt")
        #expect(ThreadWait.isSettled(.init(state: "idle", expectingSince: Self.ago(30), replyAt: Self.ago(5), lastPromptAt: Self.ago(30)),
                                     now: Self.now, waitingSince: Self.ago(60)))
    }

    /// A turn that ended with sub-agents in the background is not the end of the work: the driver opens a new turn
    /// when they report. Someone to answer, or no process, still settles it.
    @Test func aSubAgentRunningInTheBackgroundHoldsTheWait() {
        func settled(_ state: String, agents: Int, reply: TimeInterval? = nil, waitingFor: TimeInterval? = nil) -> Bool {
            ThreadWait.isSettled(.init(state: state, replyAt: Self.ago(reply), agents: agents), now: Self.now, waitingSince: Self.ago(waitingFor))
        }
        #expect(!settled("idle", agents: 1))
        #expect(!settled("done", agents: 3))
        #expect(!settled("running", agents: 1))
        #expect(settled("idle", agents: 0))
        #expect(!settled("idle", agents: 1, reply: 5, waitingFor: 60), "the answer that ended that turn says it is waiting")
        #expect(settled("waiting", agents: 1), "a question or a permission: someone must act")
        #expect(settled("exited", agents: 1) && settled("failed", agents: 1))
        let entry = ThreadWaitResult.Entry(thread: "3f9a2c17be04", title: "api", state: "idle", settled: false, agents: 2)
        #expect(entry.agents == 2)
        #expect(ThreadWaitResult.Entry(thread: "3f9a2c17be04", title: "api", state: "idle", settled: true).agents == nil)
        let text = CLIRenderer.text(.wait(ThreadWaitResult(threads: [entry], complete: false, waited: 600)))
        #expect(text.contains("(idle, still at work: 2 sub-agents running in the background)"))
    }

    /// `thread send --wait`: one call where an agent made two, every time it handed a thread something.
    @Test func aSendCanWaitForTheAnswerOnBothFacades() throws {
        let expected = ControlCall.threadSend(ThreadSendParams(thread: "3f9a2c17be04", text: "go on", wait: true, timeout: 120))
        guard case .call(let call, _) = try ScopeCLI.parse(["thread", "send", "3f9a2c17be04", "go on", "--wait", "--timeout", "120"]) else {
            Issue.record("not a call")
            return
        }
        #expect(call == expected)
        #expect(MCPBridge.call(tool: "scope_thread_send",
                               arguments: Data(#"{"thread":"3f9a2c17be04","text":"go on","wait":true,"timeout":120}"#.utf8))
                == .success(expected))
        #expect(MCPBridge.call(tool: "scope_thread_send", arguments: Data(#"{"thread":"3f9a2c17be04","message":"go on","block":true}"#.utf8))
                == .success(.threadSend(ThreadSendParams(thread: "3f9a2c17be04", text: "go on", wait: true))))
        // Keystrokes have no answer to wait for.
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "send", "3f9a2c17be04", "x", "--wait", "--no-enter"]) }
        #expect(ThreadSendParams(thread: "x", text: "y", submit: false, wait: true).waitParams == nil)
        #expect(ThreadSendParams(thread: "x", text: "y", wait: true, timeout: 30).waitParams == ThreadWaitParams(threads: ["x"], timeout: 30))
        // The socket outlasts the wait, as for `thread.wait`; a plain send keeps its short bound.
        #expect(expected.timeout > .seconds(120))
        #expect(ControlCall.threadSend(ThreadSendParams(thread: "x", text: "y")).timeout == .seconds(30))
        #expect(expected.serverDeadline(floor: .seconds(60)) > .seconds(120))
        // An older binary never sends the fields: they decode as off.
        let request = ControlRequest(caller: ControlCaller(client: "scope-cli/1"), call: expected)
        #expect(try ControlRequest.decode(request.encoded()).get() == request)
        let old = Data(#"{"rpc":1,"id":"1","method":"thread.send","caller":{"client":"scope-cli/0.9"},"params":{"thread":"x","text":"y"}}"#.utf8)
        #expect(try ControlRequest.decode(old).get().call == .threadSend(ThreadSendParams(thread: "x", text: "y")))
        #expect(MCPBridge.tools.first { $0.name == "scope_thread_send" }?.schema.contains("\"wait\"") == true)
    }

    /// The send's answer carries the wait's, decoded as an action and printed after the send line.
    @Test func aSendThatWaitedCarriesTheWaitAcrossTheWire() throws {
        let pr = PullRequestSummary(number: 38, url: URL(string: "https://github.com/acme/api/pull/38")!, title: "Rework auth",
                                    state: "open", checks: "passing", mergeable: "mergeable", review: "approved",
                                    checkedAt: Date(timeIntervalSince1970: 0))
        let wait = ThreadWaitResult(threads: [
            .init(thread: "3f9a2c17be04", title: "api", state: "done", settled: true,
                  reply: AgentReply(text: "Pushed.", at: Date(timeIntervalSince1970: 0)), task: "t1", pullRequest: pr),
        ], complete: true, waited: 42)
        let action = ActionResult(message: "typed 5 characters into 3f9a2c17be04 and pressed ↩", thread: "3f9a2c17be04", wait: wait)
        let response = ControlResponse.result(id: "1", .action(action, .threadSend))
        #expect(try ControlResponse.decode(try response.encoded(), method: .threadSend) == response)
        let text = CLIRenderer.text(.action(action, .threadSend))
        #expect(text.hasPrefix("typed 5 characters into 3f9a2c17be04 and pressed ↩\n\ndone waiting after 42s\n"))
        #expect(text.contains("Pushed."))
        #expect(text.contains("pull request #38 open · checks passing · mergeable · approved https://github.com/acme/api/pull/38 · task t1"))
        // Without a wait, the action is the one line it always was.
        let plain = ActionResult(message: "typed 5 characters", thread: "3f9a2c17be04")
        #expect(CLIRenderer.text(.action(plain, .threadSend)) == "typed 5 characters")
        #expect(!String(decoding: try ControlProtocol.makeEncoder().encode(plain), as: UTF8.self).contains("wait"))
    }

    /// What `scope list tasks` and `task show` say of a pull request: the line an agent used to run `gh pr view` for.
    @Test func aTaskCarriesItsPullRequestInTheListAndTheShow() throws {
        let url = URL(string: "https://github.com/acme/api/pull/38")!
        let seen = PullRequestSummary(number: 38, url: url, state: "open", checks: "failing", mergeable: "conflicting",
                                      review: "changesRequested", draft: true, checkedAt: Date(timeIntervalSince1970: 0))
        #expect(seen.line == "#38 open · draft · checks failing · conflicting · changes requested")
        #expect(PullRequestSummary(number: 38, url: url, state: "merged", checks: "passing", mergeable: "unknown", review: "none").line
                == "#38 merged · checks passing")
        #expect(PullRequestSummary(number: 38, url: url, state: "unknown").line == "#38 unknown")
        let task = TaskSummary(id: "t1", name: "Rework auth", slug: "rework-auth", branch: "feat/auth", scope: "Acme",
                               scopeSlug: "acme", root: "/r", repos: ["api"], threads: [], pullRequest: seen)
        let bare = TaskSummary(id: "t2", name: "Study", slug: "study", branch: "feat/study", scope: "Acme",
                               scopeSlug: "acme", root: "/s", repos: ["api"], threads: [])
        let text = CLIRenderer.text(.list(ListResult(tasks: [task, bare])))
        #expect(text.contains("PR") && text.contains("#38 open · draft · checks failing · conflicting · changes requested"))
        #expect(!String(decoding: try ControlProtocol.makeEncoder().encode(bare), as: UTF8.self).contains("pullRequest"))
        let response = ControlResponse.result(id: "1", .list(ListResult(tasks: [task, bare])))
        #expect(try ControlResponse.decode(try response.encoded(), method: .list) == response)
        let show = TaskShowResult(
            scope: "acme",
            task: .init(id: "t1", slug: "rework-auth", name: "Rework auth", branch: "feat/auth", repos: ["api"], outcome: .active,
                        createdAt: Date(timeIntervalSince1970: 0), lastActivity: Date(timeIntervalSince1970: 0),
                        pullRequest: .init(number: 38, url: url, title: "Rework auth", state: "open"),
                        pullRequests: [.init(number: 38, url: url, title: "Rework auth", state: "open")], createdByAgent: true, threads: []),
            prompt: "Rework auth", deliverable: nil, notes: [], pullRequest: seen)
        #expect(CLIRenderer.text(.taskShow(show)).contains("pr          #38 open · draft · checks failing · conflicting · changes requested https://"))
        #expect(try ControlResponse.decode(try ControlResponse.result(id: "1", .taskShow(show)).encoded(), method: .taskShow).payload == .taskShow(show))
    }

    @Test func allWaitsForEveryThreadAndAnyForTheFirst() {
        #expect(ThreadWait.isOver([true, true], until: .all))
        #expect(!ThreadWait.isOver([true, false], until: .all))
        #expect(ThreadWait.isOver([true, false], until: .any))
        #expect(!ThreadWait.isOver([false, false], until: .any))
    }

    @Test func theCommandLineAndTheMCPToolBuildTheSameCall() throws {
        let expected = ControlCall.threadWait(ThreadWaitParams(threads: ["3f9a2c17be04", "8c1d0e5a7f22"], until: .any, timeout: 120))
        guard case .call(let call, _) = try ScopeCLI.parse(["thread", "wait", "3f9a2c17be04", "8c1d0e5a7f22", "--any", "--timeout", "120"]) else {
            Issue.record("not a call")
            return
        }
        #expect(call == expected)
        #expect(MCPBridge.call(tool: "scope_thread_wait",
                               arguments: Data(#"{"threads":["3f9a2c17be04","8c1d0e5a7f22"],"until":"any","timeout":120}"#.utf8))
                == .success(expected))
        // One id, the way an agent naturally spells it.
        #expect(MCPBridge.call(tool: "scope_thread_wait", arguments: Data(#"{"thread":"3f9a2c17be04"}"#.utf8))
                == .success(.threadWait(ThreadWaitParams(threads: ["3f9a2c17be04"]))))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "wait"]) }
        #expect(MCPBridge.tools.first { $0.name == "scope_thread_wait" }?.readOnly == true)
    }

    /// The socket must outlast the wait, or the client gives up on an answer that is on its way.
    @Test func theTimeoutIsBoundedAndTheSocketOutlastsIt() {
        #expect(ThreadWaitParams(threads: ["x"]).effectiveTimeout == ThreadWaitParams.defaultTimeout)
        #expect(ThreadWaitParams(threads: ["x"], timeout: 99_999).effectiveTimeout == ThreadWaitParams.maxTimeout)
        #expect(ThreadWaitParams(threads: ["x"], timeout: 0).effectiveTimeout == 1)
        let call = ControlCall.threadWait(ThreadWaitParams(threads: ["x"], timeout: 30))
        #expect(call.timeout > .seconds(30))
    }

    @Test func aWaitCrossesTheWireBothWays() throws {
        let request = ControlRequest(caller: ControlCaller(client: "scope-cli/1"),
                                     call: .threadWait(ThreadWaitParams(threads: ["3f9a2c17be04"], until: .any)))
        #expect(try ControlRequest.decode(request.encoded()).get() == request)
        let result = ThreadWaitResult(threads: [
            .init(thread: "3f9a2c17be04", title: "api", state: "done", settled: true,
                  reply: AgentReply(text: "Merged.", at: Date(timeIntervalSince1970: 0))),
            .init(thread: "8c1d0e5a7f22", title: "web", state: "running", settled: false),
        ], complete: false, waited: 600)
        let response = ControlResponse.result(id: request.id, .wait(result))
        #expect(try ControlResponse.decode(response.encoded(), method: .threadWait).payload == response.payload)
        let text = CLIRenderer.text(.wait(result))
        #expect(text.hasPrefix("still at work after 600s: 8c1d0e5a7f22\n"))
        #expect(text.contains("Merged.") && text.contains(ThreadTranscript.untrustedNotice))
        #expect(text.contains("thread 8c1d0e5a7f22 — web (running, still at work)"))
    }

    /// Waiting answers with replies: gated like reading, never like opening.
    @Test func waitingIsGatedLikeReading() {
        let wait = ControlCall.threadWait(ThreadWaitParams(threads: ["3f9a2c17be04"]))
        let agent = ControlOrigin.thread(ThreadID(rawValue: "8c1d0e5a7f22")!, depth: 1)
        #expect(AutomationPolicy(settings: AutomationSettings(depthLimit: 1)).decide(wait, from: agent) == .allow)
        guard case .refuse = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false)).decide(wait, from: agent) else {
            Issue.record("an agent waited on a thread with agents turned off")
            return
        }
        #expect(!ControlMethod.threadWait.isMutating && ControlMethod.threadWait.isGated)
    }

    /// A wait that ends on a question, the grace or the deadline still shows the reply it has — flagged when that
    /// reply answers an earlier prompt, so it is never taken for the answer to the latest one.
    @Test func aReplyFromBeforeTheLatestPromptIsFlagged() {
        let reply = AgentReply(text: "pong", at: Self.now)
        #expect(!ThreadWait.isStale(reply, lastPromptAt: nil))
        #expect(!ThreadWait.isStale(reply, lastPromptAt: Self.now.addingTimeInterval(-5)))
        #expect(ThreadWait.isStale(reply, lastPromptAt: Self.now.addingTimeInterval(5)))
        let entry = ThreadWaitResult.Entry(thread: "3f9a2c17be04", title: "api", state: "waiting", settled: true,
                                           reply: reply, lastPromptAt: Self.now.addingTimeInterval(5))
        #expect(entry.staleReply == true)
        let text = CLIRenderer.text(.wait(ThreadWaitResult(threads: [entry], complete: true, waited: 3)))
        #expect(text.contains(CLIRenderer.staleNotice))
    }

    /// The app's socket server must not cut a wait at its usual deadline, and must answer before the client gives up.
    @Test func theServerLetsAWaitRunItsCourse() {
        let floor = Duration.seconds(180)
        let long = ControlCall.threadWait(ThreadWaitParams(threads: ["x"], timeout: 600))
        #expect(long.serverDeadline(floor: floor) > .seconds(600))
        #expect(long.serverDeadline(floor: floor) < long.timeout)
        #expect(ControlCall.threadWait(ThreadWaitParams(threads: ["x"], timeout: 5)).serverDeadline(floor: floor) == floor)
        #expect(ControlCall.taskNew(TaskNewParams(prompt: "x")).serverDeadline(floor: floor) == floor)
    }

    @Test func aWaitOnNothingIsRefused() {
        guard case .failure(let error) = MCPBridge.call(tool: "scope_thread_wait", arguments: Data(#"{"threads":[],"until":"any"}"#.utf8)) else {
            Issue.record("an empty wait was accepted"); return
        }
        #expect(error.code == .badRequest)
    }
}
