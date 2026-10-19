import Foundation
import Testing
@testable import ScopeCore

@Suite struct CommandKeyHintsTests {
    // MARK: Hold detection

    @Test func commandHeldAloneShowsAfterTheDelay() {
        var detector = CommandHoldDetector()
        #expect(detector.modifiersChanged([.command]) == .arm(generation: 1))
        #expect(detector.delayElapsed(generation: 1) == .show)
        #expect(detector.isShown)
        #expect(detector.modifiersChanged([]) == .hide)
        #expect(detector.phase == .idle)
    }

    @Test func aKeyBeforeTheDelayCancelsTheHold() {
        var detector = CommandHoldDetector()
        #expect(detector.modifiersChanged([.command]) == .arm(generation: 1))
        #expect(detector.keyDown() == .none)
        // The timer still fires; its generation is stale by then.
        #expect(detector.delayElapsed(generation: 1) == .none)
        #expect(!detector.isShown)
        #expect(detector.modifiersChanged([]) == .none)
    }

    @Test func aClickBeforeTheDelayCancelsTheHold() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        #expect(detector.mouseDown() == .none)
        #expect(detector.delayElapsed(generation: 1) == .none)
    }

    @Test func aSecondModifierBeforeTheDelayCancelsTheHold() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        #expect(detector.modifiersChanged([.command, .shift]) == .none)
        #expect(detector.delayElapsed(generation: 1) == .none)
        #expect(detector.phase == .idle)
    }

    @Test func commandWithAnotherModifierNeverArms() {
        var detector = CommandHoldDetector()
        #expect(detector.modifiersChanged([.command, .option]) == .none)
        #expect(detector.modifiersChanged([.shift]) == .none)
        #expect(detector.phase == .idle)
    }

    @Test func anInactiveAppNeverArms() {
        var detector = CommandHoldDetector()
        #expect(detector.modifiersChanged([.command], appActive: false) == .none)
        #expect(detector.phase == .idle)
    }

    @Test func aStaleTimerNeverShows() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        _ = detector.modifiersChanged([])
        #expect(detector.modifiersChanged([.command]) == .arm(generation: 2))
        #expect(detector.delayElapsed(generation: 1) == .none)
        #expect(detector.delayElapsed(generation: 2) == .show)
    }

    @Test func aRepeatOfCommandAloneKeepsTheHold() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        #expect(detector.modifiersChanged([.command]) == .none)
        #expect(detector.delayElapsed(generation: 1) == .show)
    }

    @Test func theChordTypedWhileShownKeepsTheHintsUntilCommandGoesUp() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        _ = detector.delayElapsed(generation: 1)
        // ⇧⌘N: shift joins, N is typed, shift leaves, then ⌘.
        #expect(detector.modifiersChanged([.command, .shift]) == .none)
        #expect(detector.keyDown() == .none)
        #expect(detector.isShown)
        #expect(detector.modifiersChanged([.command]) == .none)
        #expect(detector.modifiersChanged([]) == .hide)
    }

    @Test func aCommandClickWhileShownKeepsTheHints() {
        var detector = CommandHoldDetector()
        _ = detector.modifiersChanged([.command])
        _ = detector.delayElapsed(generation: 1)
        #expect(detector.mouseDown() == .none)
        #expect(detector.isShown)
    }

    @Test func losingTheAppHidesOrCancels() {
        var shown = CommandHoldDetector()
        _ = shown.modifiersChanged([.command])
        _ = shown.delayElapsed(generation: 1)
        #expect(shown.interrupted() == .hide)
        #expect(shown.phase == .idle)

        var armed = CommandHoldDetector()
        _ = armed.modifiersChanged([.command])
        #expect(armed.interrupted() == .none)
        #expect(armed.delayElapsed(generation: 1) == .none)
    }

    // MARK: Key equivalents

    @Test func readsMenuKeyEquivalentsAsTheMenuBarDraws() {
        #expect(KeyEquivalentText.describe(key: "t", modifiers: [.command]) == "⌘T")
        #expect(KeyEquivalentText.describe(key: "t", modifiers: [.command, .shift]) == "⇧⌘T")
        #expect(KeyEquivalentText.describe(key: "k", modifiers: [.command, .option]) == "⌥⌘K")
        #expect(KeyEquivalentText.describe(key: "s", modifiers: [.command, .control]) == "⌃⌘S")
        #expect(KeyEquivalentText.describe(key: "1", modifiers: [.control]) == "⌃1")
        #expect(KeyEquivalentText.describe(key: ".", modifiers: [.command]) == "⌘.")
        #expect(KeyEquivalentText.describe(key: "]", modifiers: [.command, .shift]) == "⇧⌘]")
    }

    @Test func namesTheKeysWithoutACharacter() {
        #expect(KeyEquivalentText.describe(key: "\r", modifiers: [.command, .option]) == "⌥⌘↩")
        #expect(KeyEquivalentText.describe(key: "\u{F703}", modifiers: [.command, .option]) == "⌥⌘→")
        #expect(KeyEquivalentText.describe(key: "\u{F702}", modifiers: [.command, .option]) == "⌥⌘←")
        #expect(KeyEquivalentText.describe(key: "\u{1b}", modifiers: []) == "⎋")
        #expect(KeyEquivalentText.describe(key: " ", modifiers: [.option]) == "⌥Space")
        #expect(KeyEquivalentText.describe(key: "\u{7f}", modifiers: [.command]) == "⌘⌫")
    }

    @Test func aCapitalKeyMeansShift() {
        #expect(KeyEquivalentText.describe(key: "N", modifiers: [.command]) == "⇧⌘N")
        #expect(KeyEquivalentText.describe(key: "N", modifiers: [.command, .shift]) == "⇧⌘N")
    }

    @Test func anItemWithoutAKeyHasNoHint() {
        #expect(KeyEquivalentText.describe(key: "", modifiers: [.command]) == nil)
    }

    // MARK: Index

    @Test func theFirstEnabledEntryWins() {
        let index = KeyHintIndex(entries: [
            .init(id: "command.find-files", keys: "⌘P"),
            .init(id: "command.find-files", keys: "⇧⌘O"),
            .init(id: "command.new-task", keys: "⇧⌘T", enabled: false),
            .init(id: "command.undo-close", keys: "⇧⌘T"),
        ])
        #expect(index.keys(for: "command.find-files") == "⌘P")
        #expect(index.keys(for: "command.new-task") == nil)
        #expect(index.keys(for: "command.undo-close") == "⇧⌘T")
        #expect(index.keys(for: "command.nothing") == nil)
        #expect(!index.isEmpty)
        #expect(KeyHintIndex().isEmpty)
    }

    @Test func numberedIDs() {
        #expect(KeyHintIndex.threadID(3) == "command.thread-3")
        #expect(KeyHintIndex.scopeID(1) == "command.scope-1")
    }
}
