import Testing
@testable import ScopeTasks

@Suite struct ThreadInputTests {
    private let start = "\u{1b}[200~", end = "\u{1b}[201~"

    @Test func aMultilineMessageIsOnePasteWhenTheProgramAskedForIt() {
        let input = ThreadDelivery.input("[Scope: message]\nfirst\nsecond", bracketedPasteMode: true)
        #expect(input == start + "[Scope: message]\rfirst\rsecond" + end)
        // Nothing outside the envelope: no line break the program could take for ↩ before the whole text is in.
        #expect(input.hasPrefix(start) && input.hasSuffix(end))
    }

    @Test func lineBreaksAreTypedTheWayATerminalPastesThem() {
        #expect(ThreadDelivery.input("a\r\nb\nc\rd", bracketedPasteMode: true) == start + "a\rb\rc\rd" + end)
        #expect(ThreadDelivery.input("a\r\nb\nc", bracketedPasteMode: false) == "a\rb\rc")
    }

    @Test func aProgramWithoutBracketedPasteGetsNoMarkers() {
        #expect(ThreadDelivery.input("echo hi", bracketedPasteMode: false) == "echo hi")
    }

    @Test func aLongMessageKeepsEveryLineAndCannotCloseThePasteEarly() {
        let body = (1...400).map { "line \($0) of a long review" }.joined(separator: "\n") + "\n\u{1b}[201~tail"
        let input = ThreadDelivery.input(body, bracketedPasteMode: true)
        #expect(input.components(separatedBy: end).count == 2)
        #expect(input.contains("line 400 of a long review\rtail"))
        #expect(input.split(separator: "\r").count == 401)
    }

    @Test func theReturnWaitsLongerForALongerInputWithinABound() {
        #expect(ThreadDelivery.submitDelay(forByteCount: 10) == .milliseconds(150))
        #expect(ThreadDelivery.submitDelay(forByteCount: 8 * 1_024) == .milliseconds(550))
        #expect(ThreadDelivery.submitDelay(forByteCount: 1_000_000) == .seconds(1))
        #expect(ThreadDelivery.submitDelay(forByteCount: 4_096) > ThreadDelivery.submitDelay(forByteCount: 100))
    }
}
