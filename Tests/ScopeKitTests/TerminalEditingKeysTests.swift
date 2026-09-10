import Foundation
import ScopeCore
import Testing

/// ⌥ is either a way to type a character or the Meta key; these are the four bindings that survive both.
@Suite struct TerminalEditingKeysTests {
    @Test func theFourNavigationKeysKeepTheirMeaning() {
        #expect(TerminalEditingKeys.optionSequence(keyCode: TerminalEditingKeys.Code.leftArrow) == [0x1b, 0x62])   // ESC b
        #expect(TerminalEditingKeys.optionSequence(keyCode: TerminalEditingKeys.Code.rightArrow) == [0x1b, 0x66])  // ESC f
        #expect(TerminalEditingKeys.optionSequence(keyCode: TerminalEditingKeys.Code.backspace) == [0x1b, 0x7f])   // ESC DEL
        #expect(TerminalEditingKeys.optionSequence(keyCode: TerminalEditingKeys.Code.forwardDelete) == [0x1b, 0x64]) // ESC d
    }

    /// Everything else composes a character — `⌥)` is `}` on a French layout — and must be left alone.
    @Test func anyKeyThatComposesACharacterIsLeftToTheSystem() {
        for keyCode in [UInt16(30), 33, 25, 29, 0, 11, 36, 48] {   // ) ( 9 0 a b ↩ ⇥
            #expect(TerminalEditingKeys.optionSequence(keyCode: keyCode) == nil)
        }
    }

    /// ⌘ plus an arrow means "to the end of the line" on macOS, and that is `^A` / `^E` to a shell.
    @Test func commandAndAnArrowReachTheEndsOfTheLine() {
        #expect(TerminalEditingKeys.commandSequence(keyCode: TerminalEditingKeys.Code.leftArrow) == [0x01])   // ^A
        #expect(TerminalEditingKeys.commandSequence(keyCode: TerminalEditingKeys.Code.rightArrow) == [0x05])  // ^E
        #expect(TerminalEditingKeys.commandSequence(keyCode: TerminalEditingKeys.Code.backspace) == [0x15])   // ^U
        #expect(TerminalEditingKeys.commandSequence(keyCode: TerminalEditingKeys.Code.forwardDelete) == [0x0b]) // ^K
    }

    /// ⌘ with anything else is a menu shortcut, not something to swallow.
    @Test func commandWithAnyOtherKeyIsLeftAlone() {
        for keyCode in [UInt16(36), 48, 0, 12, 126, 125] {   // ↩ ⇥ a q ↑ ↓
            #expect(TerminalEditingKeys.commandSequence(keyCode: keyCode) == nil)
        }
    }

    /// ⌥ composing a character is the default, as in Terminal and iTerm.
    @Test func optionIsNotMetaByDefault() {
        #expect(!Preferences.default.terminalOptionAsMeta)
    }

    @Test func thePreferenceSurvivesAnOlderConfig() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"terminalFontSize":14}"#.utf8))
        #expect(!old.terminalOptionAsMeta)
        let set = try JSONDecoder().decode(Preferences.self, from: Data(#"{"terminalOptionAsMeta":true}"#.utf8))
        #expect(set.terminalOptionAsMeta)
    }
}
