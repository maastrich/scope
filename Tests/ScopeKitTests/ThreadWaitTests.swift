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
        #expect(AutomationPolicy(settings: AutomationSettings(maxDepth: 1)).decide(wait, from: agent) == .allow)
        guard case .refuse = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false)).decide(wait, from: agent) else {
            Issue.record("an agent waited on a thread with agents turned off")
            return
        }
        #expect(!ControlMethod.threadWait.isMutating && ControlMethod.threadWait.isGated)
    }
}
