import Foundation

/// What ⌥ plus a navigation key must send when ⌥ is *not* the Meta key.
///
/// A terminal has to choose what ⌥ does. Treating it as Meta (`ESC` before the character) is what shells
/// want for `M-b` / `M-f`, but it reads the key *ignoring modifiers*, so on a keyboard where a brace is
/// typed with ⌥ — `⌥(` and `⌥)` on a French layout, `⌥8` / `⌥9` on a Swiss one — the brace can never be
/// typed at all. macOS Terminal and iTerm both default to composing the character instead.
///
/// Scope does the same, and puts back by hand the four bindings that would be lost: they carry no character
/// to compose, so nothing is given up.
public enum TerminalOptionKey {
    /// The virtual key codes involved (`NSEvent.keyCode`, stable across layouts — they are positions).
    public enum Code {
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let backspace: UInt16 = 51
        public static let forwardDelete: UInt16 = 117
    }

    /// The bytes ⌥ plus `keyCode` sends, or `nil` when the key composes a character and must be left to the
    /// system.
    ///
    /// | Key | Sends | Means |
    /// |---|---|---|
    /// | ⌥← | `ESC b` | back one word |
    /// | ⌥→ | `ESC f` | forward one word |
    /// | ⌥⌫ | `ESC DEL` | delete the word before the caret |
    /// | ⌥⌦ | `ESC d` | delete the word after the caret |
    public static func sequence(keyCode: UInt16) -> [UInt8]? {
        switch keyCode {
        case Code.leftArrow: [0x1b, 0x62]
        case Code.rightArrow: [0x1b, 0x66]
        case Code.backspace: [0x1b, 0x7f]
        case Code.forwardDelete: [0x1b, 0x64]
        default: nil
        }
    }
}
