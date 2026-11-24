import Foundation
import Testing
import ScopeCore
@testable import ScopeAdapters

/// 110 `turn.interrupted unknown` in two weeks: the journal now names the last hook seen before the cut.
@Suite struct TurnInterruptionTests {
    private let thread = ThreadID.generate()

    private func hook(_ name: String, kind: HookEvent.Kind = .driverReported, extra: String = "") -> AdapterEvent {
        AdapterEvent(threadID: thread, kind: kind, payload: [HookEvent.hookKey: #"{"hook_event_name":"\#(name)"\#(extra)}"#])
    }

    @Test func whatTheSessionKnowsWinsThenTheKeyboardThenTheLastHook() {
        #expect(TurnInterruption.cause(known: "esc", typed: true, lastHook: "stop-failure") == "esc")
        #expect(TurnInterruption.cause(known: nil, typed: true, lastHook: "stop-failure") == "typed")
        #expect(TurnInterruption.cause(known: nil, typed: false, lastHook: "stop-failure") == "after:stop-failure")
        #expect(TurnInterruption.cause(known: nil, typed: false, lastHook: nil) == "unknown")
    }

    @Test(arguments: [
        ("StopFailure", "stop-failure"),
        ("PermissionDenied", "permission-denied"),
        ("PostToolUseFailure", "post-tool-use-failure"),
        ("SubagentStop", "subagent-stop"),
        ("Notification", "notification"),
    ])
    func aClaudeHookGoesByItsOwnName(name: String, expected: String) {
        #expect(TurnInterruption.hookName(of: hook(name)) == expected)
    }

    /// The hook's name says more than the event it was normalized to: `PostToolUse` and `UserPromptSubmit` are both
    /// `turn.started`.
    @Test func theHookNameBeatsTheNormalizedEvent() {
        #expect(TurnInterruption.hookName(of: hook("PostToolUse", kind: .turnStarted)) == "post-tool-use")
        #expect(TurnInterruption.hookName(of: hook("UserPromptSubmit", kind: .turnStarted)) == "user-prompt-submit")
    }

    @Test func aDriverWithoutHookPayloadGoesByTheEvent() {
        #expect(TurnInterruption.hookName(of: AdapterEvent(threadID: thread, kind: .permissionRequested)) == "permission.requested")
        #expect(TurnInterruption.hookName(of: AdapterEvent(threadID: thread, kind: .turnStarted, payload: [HookEvent.toolKey: "Bash"])) == "turn.started")
    }

    /// The status line comes with every message: it would hide the hook that matters.
    @Test func theStatusLineIsNoHook() {
        #expect(TurnInterruption.hookName(of: AdapterEvent(threadID: thread, kind: .limitsReported, payload: [HookEvent.contextKey: "{}"])) == nil)
    }

    /// Only the hook's name leaves: nothing it carried, and nothing that is not a plain name.
    @Test func nothingTheHookCarriedReachesTheJournal() {
        let event = hook("PermissionDenied", extra: #","tool_name":"mcp__acme__deploy","reason":"/Users/me/secret""#)
        #expect(TurnInterruption.hookName(of: event) == "permission-denied")
        #expect(TurnInterruption.hookName(of: hook("Some Hook/With Path")) == nil)
        #expect(TurnInterruption.hookName(of: hook(String(repeating: "A", count: 40))) == nil)
    }

    @Test func everyCauseSurvivesTheJournal() {
        for kind in HookEvent.Kind.allCases {
            guard let name = TurnInterruption.hookName(of: AdapterEvent(threadID: thread, kind: kind)) else { continue }
            let cause = TurnInterruption.cause(known: nil, typed: false, lastHook: name)
            #expect(JournalEvent.token(cause) == cause)
        }
        let cause = TurnInterruption.cause(known: nil, typed: false, lastHook: TurnInterruption.hookName(of: hook("PostToolUseFailure")))
        #expect(JournalEvent.token(cause) == cause)
    }
}
