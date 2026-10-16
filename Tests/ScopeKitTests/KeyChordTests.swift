import Foundation
import Testing
@testable import ScopeCore

@Suite struct KeyChordTests {
    @Test func formatsModifiersInTheMenuBarOrder() {
        let chord = KeyChord(keyCode: 40, modifiers: [.command, .control, .shift, .option], key: "K")
        #expect(chord.description == "⌃⌥⇧⌘K")
        #expect(KeyChord.optionSpace.description == "⌥Space")
        #expect(KeyChord.optionShiftSpace.description == "⌥⇧Space")
    }

    @Test func parsesGlyphsAndWords() {
        #expect(KeyChord(parsing: "⌥Space") == .optionSpace)
        #expect(KeyChord(parsing: "alt+space") == .optionSpace)
        #expect(KeyChord(parsing: "ctrl+shift+k") == KeyChord(keyCode: 40, modifiers: [.control, .shift], key: "K"))
        #expect(KeyChord(parsing: "⌘⇧F5") == KeyChord(keyCode: 96, modifiers: [.command, .shift], key: "F5"))
        #expect(KeyChord(parsing: "cmd+⇧k")?.modifiers == [.command, .shift])
        #expect(KeyChord(parsing: " ⌃Esc ")?.key == "Escape")
    }

    @Test func refusesWhatItCannotName() {
        #expect(KeyChord(parsing: "") == nil)
        #expect(KeyChord(parsing: "⌥") == nil)
        #expect(KeyChord(parsing: "⌥Hyper") == nil)
        #expect(KeyChord(parsing: "super+k") == nil)
    }

    @Test func descriptionRoundTripsThroughParsing() {
        for chord in [KeyChord.optionSpace, KeyChord.optionShiftSpace, KeyChord(parsing: "⌃⌥⇧⌘F12")!, KeyChord(parsing: "⌘-")!] {
            #expect(KeyChord(parsing: chord.description) == chord)
        }
    }

    @Test func aBareKeyIsNotASystemWideHotkeyUnlessItIsAFunctionKey() {
        #expect(!KeyChord(keyCode: 49, modifiers: [], key: "Space").isUsableSystemWide)
        #expect(!KeyChord(keyCode: 0, modifiers: [], key: "A").isUsableSystemWide)
        #expect(KeyChord(keyCode: 96, modifiers: [], key: "F5").isUsableSystemWide)
        #expect(KeyChord.optionSpace.isUsableSystemWide)
    }

    @Test func carbonFlagsMatchEventsH() {
        #expect(KeyChord.Modifiers.command.carbonFlags == 0x0100)
        #expect(KeyChord.Modifiers.shift.carbonFlags == 0x0200)
        #expect(KeyChord.Modifiers.option.carbonFlags == 0x0800)
        #expect(KeyChord.Modifiers.control.carbonFlags == 0x1000)
        #expect(KeyChord.optionShiftSpace.modifiers.carbonFlags == 0x0A00)
    }

    @Test func namesTheKeysThatHaveNoCharacter() {
        #expect(KeyChord.keyName(49) == "Space")
        #expect(KeyChord.keyName(36) == "Return")
        #expect(KeyChord.keyName(123) == "←")
        #expect(KeyChord.keyName(999) == nil)
        #expect(KeyChord.keyCode(named: "spacebar") == 49)
        #expect(KeyChord.keyCode(named: "f19") == 80)
        #expect(KeyChord(keyCode: 999, modifiers: .option) == nil)
    }

    @Test func encodesAsAnObjectTheUserCanEdit() throws {
        let data = try JSONEncoder().encode(KeyChord.optionSpace)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["keyCode"] as? Int == 49)
        #expect(object?["key"] as? String == "Space")
        #expect(try JSONDecoder().decode(KeyChord.self, from: data) == .optionSpace)
    }

    @Test func preferencesDefaultToTheTwoChordsAndKeepAnExplicitOff() throws {
        let defaults = Preferences()
        #expect(defaults.quickPanelHotkey == .optionSpace)
        #expect(defaults.toggleWindowHotkey == .optionShiftSpace)
        #expect(defaults.quickPanelLanding == .inboxWhenWaiting)

        let missing = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(missing.quickPanelHotkey == .optionSpace)

        let off = try JSONDecoder().decode(Preferences.self, from: Data(#"{"quickPanelHotkey": null, "toggleWindowHotkey": null}"#.utf8))
        #expect(off.quickPanelHotkey == nil)
        #expect(off.toggleWindowHotkey == nil)

        let broken = try JSONDecoder().decode(Preferences.self, from: Data(#"{"quickPanelHotkey": "nonsense", "quickPanelLanding": "sideways"}"#.utf8))
        #expect(broken.quickPanelHotkey == nil)
        #expect(broken.quickPanelLanding == .inboxWhenWaiting)

        var custom = Preferences()
        custom.quickPanelHotkey = KeyChord(parsing: "⌃⌥K")
        custom.quickPanelLanding = .inbox
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(custom))
        #expect(back.quickPanelHotkey == KeyChord(parsing: "⌃⌥K"))
        #expect(back.quickPanelLanding == .inbox)
    }
}
