import Foundation
import ScopeCore
import Testing

/// ⌥ is either a way to type a character or the Meta key; these are the four bindings that survive both.
@Suite struct TerminalOptionKeyTests {
    @Test func theFourNavigationKeysKeepTheirMeaning() {
        #expect(TerminalOptionKey.sequence(keyCode: TerminalOptionKey.Code.leftArrow) == [0x1b, 0x62])   // ESC b
        #expect(TerminalOptionKey.sequence(keyCode: TerminalOptionKey.Code.rightArrow) == [0x1b, 0x66])  // ESC f
        #expect(TerminalOptionKey.sequence(keyCode: TerminalOptionKey.Code.backspace) == [0x1b, 0x7f])   // ESC DEL
        #expect(TerminalOptionKey.sequence(keyCode: TerminalOptionKey.Code.forwardDelete) == [0x1b, 0x64]) // ESC d
    }

    /// Everything else composes a character — `⌥)` is `}` on a French layout — and must be left alone.
    @Test func anyKeyThatComposesACharacterIsLeftToTheSystem() {
        for keyCode in [UInt16(30), 33, 25, 29, 0, 11, 36, 48] {   // ) ( 9 0 a b ↩ ⇥
            #expect(TerminalOptionKey.sequence(keyCode: keyCode) == nil)
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
