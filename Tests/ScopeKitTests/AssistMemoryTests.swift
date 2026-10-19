import Foundation
import Testing
import ScopeCore
@testable import ScopeAssist

/// Spec §4.10: the same words are classified once; a change is classified again; one verdict, one notification.
@Suite struct AssistMemoryTests {
    let a = ThreadID(rawValue: "aaaaaaaaaaaa")!
    let b = ThreadID(rawValue: "bbbbbbbbbbbb")!

    @Test func theSameWordsGetTheSameVerdictWithoutAsking() {
        var memory = AssistMemory()
        #expect(memory.triage(of: a, for: "Done. Next?") == nil)
        memory.rememberTriage(of: a, for: "Done. Next?", verdict: .init(kind: .blockingQuestion))
        #expect(memory.triage(of: a, for: "Done. Next?")?.verdict.kind == .blockingQuestion)
        #expect(memory.triage(of: b, for: "Done. Next?") == nil)
    }

    @Test func differentWordsAreAskedAgain() {
        var memory = AssistMemory()
        memory.rememberTriage(of: a, for: "Done. Next?", verdict: .init(kind: .blockingQuestion))
        #expect(memory.triage(of: a, for: "All green, merged.") == nil)
    }

    @Test func aHandledVerdictBringsNoSecondNotification() {
        var memory = AssistMemory()
        memory.rememberTriage(of: a, for: "Which branch?", verdict: .init(kind: .blockingQuestion))
        #expect(memory.triage(of: a, for: "Which branch?")?.handled == false)
        memory.markHandled(a)
        #expect(memory.triage(of: a, for: "Which branch?")?.handled == true)
    }

    @Test func notBlockingTurnsTheVerdictInformationalAndKeepsItHandled() {
        var memory = AssistMemory()
        memory.rememberTriage(of: a, for: "Which branch?", verdict: .init(kind: .blockingQuestion), handled: true)
        memory.overruleTriage(of: a)
        let known = memory.triage(of: a, for: "Which branch?")
        #expect(known?.verdict.kind == .informational)
        #expect(known?.handled == true)
        #expect(!(known?.verdict.interrupts ?? true))
    }

    @Test func anUnchangedTailIsNotDigestedAgainAndANewOneIs() {
        var memory = AssistMemory()
        let same = TranscriptTail.fingerprint(of: ["$ swift test", "error: x", "⠋ 12s"])
        #expect(!memory.digestIsCurrent(for: a, tailFingerprint: same))
        memory.rememberDigest(of: a, tailFingerprint: same)
        #expect(memory.digestIsCurrent(for: a, tailFingerprint: same))
        let spinnerOnly = TranscriptTail.fingerprint(of: ["$ swift test", "error: x", "⠙ 18s"])
        #expect(memory.digestIsCurrent(for: a, tailFingerprint: spinnerOnly))
        let moved = TranscriptTail.fingerprint(of: ["$ swift test", "error: x", "error: y", "⠙ 18s"])
        #expect(!memory.digestIsCurrent(for: a, tailFingerprint: moved))
    }

    @Test func aNewTurnForgetsTheTailAndAClosedThreadEverything() {
        var memory = AssistMemory()
        memory.rememberDigest(of: a, tailFingerprint: 1)
        memory.rememberTriage(of: a, for: "x", verdict: .init(kind: .failure))
        memory.turnStarted(a)
        #expect(!memory.digestIsCurrent(for: a, tailFingerprint: 1))
        #expect(memory.triage(of: a, for: "x") != nil)
        memory.forget(a)
        #expect(memory.triage(of: a, for: "x") == nil)
    }
}
