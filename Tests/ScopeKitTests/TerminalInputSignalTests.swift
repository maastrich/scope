import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

@Suite struct TerminalInputSignalTests {
    func feed(_ tracker: inout TerminalInputTracker, _ text: String) -> TerminalInputSignal? {
        tracker.feed(Array(text.utf8))
    }

    @Test func loneEscapeAndControlCInterrupt() {
        var tracker = TerminalInputTracker()
        #expect(feed(&tracker, "\u{1b}") == .interrupt)
        #expect(feed(&tracker, "\u{03}") == .interrupt)
    }

    @Test func escapeSequencesAreNeitherInterruptNorText() {
        var tracker = TerminalInputTracker()
        #expect(feed(&tracker, "\u{1b}[A") == nil)          // arrow up
        #expect(feed(&tracker, "\u{1b}[I") == nil)          // focus in
        #expect(feed(&tracker, "\r") == .submit(hadText: false))
    }

    @Test func returnSaysWhetherAPromptWasTyped() {
        var tracker = TerminalInputTracker()
        #expect(feed(&tracker, "\r") == .submit(hadText: false))
        #expect(feed(&tracker, "f") == nil)
        #expect(feed(&tracker, "ix it") == nil)
        #expect(feed(&tracker, "\r") == .submit(hadText: true))
        // The line was consumed: the next Return is an empty one.
        #expect(feed(&tracker, "\r") == .submit(hadText: false))
        #expect(feed(&tracker, "go\r") == .submit(hadText: true))
    }

    @Test func aBracketedPasteCountsAsText() {
        var tracker = TerminalInputTracker()
        #expect(feed(&tracker, "\u{1b}[200~pasted\u{1b}[201~") == nil)
        #expect(feed(&tracker, "\r") == .submit(hadText: true))
    }

    @Test func controlCForgetsTheTypedLine() {
        var tracker = TerminalInputTracker()
        _ = feed(&tracker, "half a prompt")
        #expect(feed(&tracker, "\u{03}") == .interrupt)
        #expect(feed(&tracker, "\r") == .submit(hadText: false))
    }

    @Test func interruptEndsARunningOrWaitingTurnOnly() {
        for state in [ThreadState.running, .waiting(reason: .input), .waiting(reason: .permission)] {
            #expect(ThreadStateMachine.next(state, onUserInput: .interrupt, adapterReportsTurnStart: true) == .idle)
        }
        for state in [ThreadState.idle, .done, .failed, .exited] {
            #expect(ThreadStateMachine.next(state, onUserInput: .interrupt, adapterReportsTurnStart: true) == nil)
        }
    }

    @Test func returnOnAPermissionPromptResumesTheTurn() {
        let next = ThreadStateMachine.next(.waiting(reason: .permission), onUserInput: .submit(hadText: false),
                                           adapterReportsTurnStart: true)
        #expect(next == .running)
        // A question (AskUserQuestion) can span several screens; its PostToolUse says when it is answered.
        #expect(ThreadStateMachine.next(.waiting(reason: .input), onUserInput: .submit(hadText: true),
                                        adapterReportsTurnStart: true) == nil)
    }

    @Test func aTypedPromptStartsATurnOnlyWhenTheAdapterCannotSaySo() {
        for state in [ThreadState.idle, .done, .failed] {
            #expect(ThreadStateMachine.next(state, onUserInput: .submit(hadText: true), adapterReportsTurnStart: false) == .running)
            #expect(ThreadStateMachine.next(state, onUserInput: .submit(hadText: true), adapterReportsTurnStart: true) == nil)
            #expect(ThreadStateMachine.next(state, onUserInput: .submit(hadText: false), adapterReportsTurnStart: false) == nil)
        }
        #expect(ThreadStateMachine.next(.exited, onUserInput: .submit(hadText: true), adapterReportsTurnStart: false) == nil)
    }
}
