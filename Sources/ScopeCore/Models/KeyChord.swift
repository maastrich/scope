import Foundation

/// A key with its modifiers, as a system-wide hotkey is declared: the quick panel's ⌥Space, the window toggle's
/// ⌥⇧Space. Pure data — what the recorder in Settings stores, what `config.json` keeps, what the app hands to
/// `RegisterEventHotKey` — so the parsing and the formatting are testable without AppKit.
///
/// A chord is a *virtual key code*, not a character: the hotkey must fire on the same physical key whatever the
/// layout, and that is what Carbon registers. `key` is only the name shown for it, taken from the layout when the
/// chord was recorded (`Space`, `A`, `É`); for the keys that have no character it comes from `keyName(_:)`.
public struct KeyChord: Codable, Sendable, Hashable, CustomStringConvertible {
    /// The modifiers of a chord, in the order macOS writes them: ⌃ ⌥ ⇧ ⌘.
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// The glyphs, in the order the menu bar draws them.
        public var description: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }

        /// The mask `RegisterEventHotKey` takes (`cmdKey`, `shiftKey`, `optionKey`, `controlKey` of Carbon's Events.h).
        public var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= 0x0100 }
            if contains(.shift) { flags |= 0x0200 }
            if contains(.option) { flags |= 0x0800 }
            if contains(.control) { flags |= 0x1000 }
            return flags
        }
    }

    /// The virtual key code (`kVK_*` of Carbon's Events.h): 49 is Space on every layout.
    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// The key's name as shown: a capital letter, a digit, or `keyName(_:)` for a key without a character.
    public var key: String

    public init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A chord on a key the table names (`Space`, `F5`, a letter of the US layout), with the name filled in.
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        guard let name = KeyChord.keyName(keyCode) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: name)
    }

    /// `⌥Space`, `⌃⇧F5`, `⌘K`.
    public var description: String { modifiers.description + key }

    /// Whether a system-wide hotkey may be made of this: a bare letter or Space would take the key away from every
    /// app, so one modifier at least — except for the function keys, which are hotkeys on their own.
    public var isUsableSystemWide: Bool {
        !modifiers.isEmpty || KeyChord.functionKeyCodes.contains(keyCode)
    }

    /// The quick panel's default, ⌥Space: free on a fresh Mac, and the chord launchers have taught.
    public static let optionSpace = KeyChord(keyCode: 49, modifiers: .option, key: "Space")
    /// The window toggle's default, ⌥⇧Space: one finger more on the same chord.
    public static let optionShiftSpace = KeyChord(keyCode: 49, modifiers: [.option, .shift], key: "Space")

    // MARK: Parsing

    /// `⌥Space`, `ctrl+shift+k`, `⌘⇧F5`: the modifiers as glyphs or words (`ctrl`, `control`, `alt`, `opt`,
    /// `option`, `shift`, `cmd`, `command`), the key as the table names it or a letter or digit of the US layout.
    /// `nil` when the key is unknown.
    public init?(parsing text: String) {
        var modifiers = Modifiers()
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        // Words first (`ctrl+shift+k`), then glyphs (`⌃⇧K`); the two may mix.
        while let plus = rest.firstIndex(of: "+"), let word = Self.modifierWords[rest[..<plus].lowercased()] {
            modifiers.insert(word)
            rest = rest[rest.index(after: plus)...]
        }
        while let first = rest.first, let glyph = Self.modifierGlyphs[first] {
            modifiers.insert(glyph)
            rest = rest.dropFirst()
        }
        let name = String(rest)
        guard !name.isEmpty, let code = Self.keyCode(named: name) else { return nil }
        self.init(keyCode: code, modifiers: modifiers, key: Self.keyName(code) ?? name.uppercased())
    }

    private static let modifierGlyphs: [Character: Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
    private static let modifierWords: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "alt": .option, "opt": .option, "option": .option,
        "shift": .shift, "cmd": .command, "command": .command,
    ]

    // MARK: Key names

    /// The name of a key that has no character of its own, and of the US layout's letters, digits and punctuation
    /// (the names Carbon's `kVK_ANSI_*` constants give them). `nil` for a code the table does not know.
    public static func keyName(_ keyCode: UInt16) -> String? {
        namesByCode[keyCode]
    }

    /// The reverse of `keyName(_:)`, case-insensitive; `space` and `spacebar` both name 49.
    public static func keyCode(named name: String) -> UInt16? {
        codesByName[name.lowercased()]
    }

    /// `F1`…`F19`: the keys that need no modifier.
    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80]

    private static let namesByCode: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Escape", 51: "Delete", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    private static let codesByName: [String: UInt16] = {
        var table: [String: UInt16] = [:]
        for (code, name) in namesByCode { table[name.lowercased()] = code }
        table["spacebar"] = 49
        table["esc"] = 53
        table["backspace"] = 51
        table["left"] = 123
        table["right"] = 124
        table["down"] = 125
        table["up"] = 126
        return table
    }()
}
