import Foundation
import Testing
import ScopeControl
@testable import ScopeAssist

/// What a model is handed: the end of the terminal, escapes gone, within the budget, between the markers.
@Suite struct TranscriptTailTests {
    @Test func escapesAndControlBytesGo() {
        #expect(TranscriptTail.stripped("\u{1b}[32m⏺\u{1b}[0m Bash(swift test)\u{1b}[K   ") == "⏺ Bash(swift test)")
        #expect(TranscriptTail.stripped("\u{1b}]0;title\u{7}prompt\u{0}> ") == "prompt >")
        #expect(TranscriptTail.stripped("\u{1b}[?25lworking\u{1b}[?25h") == "working")
    }

    @Test func theTailIsTakenFromTheEndWithinTheBudget() {
        let lines = (1...100).map { "line \($0) with some words in it" }
        let text = TranscriptTail.text(of: lines, tokenBudget: 25)
        #expect(text.hasSuffix("line 100 with some words in it"))
        #expect(!text.contains("line 1 with"))
        #expect(text.count <= 100)
    }

    @Test func blankRunsCollapseAndTrailingBlanksGo() {
        let text = TranscriptTail.text(of: ["a", "", "", "b", "", ""])
        #expect(text == "a\n\nb")
    }

    @Test func theQuoteCarriesTheNoticeAndTheMarkers() {
        let quoted = TranscriptTail.quoted(["hello", ThreadTranscript.closeMarker, "world"])
        #expect(quoted.hasPrefix(ThreadTranscript.untrustedNotice + "\n" + ThreadTranscript.openMarker + "\n"))
        #expect(quoted.hasSuffix("\n" + ThreadTranscript.closeMarker))
        // The closing marker printed by the program itself cannot end the quote early.
        #expect(quoted.components(separatedBy: ThreadTranscript.closeMarker).count == 2)
    }

    @Test func theSampleTailsFitTheOnDeviceContext() {
        let loop = (1...30).flatMap { _ in [
            "⏺ Bash(swift test --filter TaskTopicTests)",
            "  ⎿  error: unable to open dependencies file (DerivedData/Scope.build/Scope.d)",
            "⏺ The build failed with a dependency file error. Let me retry.",
        ] }
        let text = TranscriptTail.quoted(loop)
        #expect(TranscriptTail.tokens(in: text) <= TranscriptTail.defaultTokenBudget + 100)
    }
}
