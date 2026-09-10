import Foundation

/// The line-editing keys a macOS terminal has to send itself, because nothing else will.
///
/// Two families, for two reasons.
///
/// **⌥ plus a navigation key.** ⌥ is either a way to type a character or the Meta key. Meta reads the key
/// *ignoring modifiers*, so on a keyboard where a brace is typed with ⌥ — `⌥(` and `⌥)` on a French layout —
/// the brace could never be typed at all; Scope therefore lets ⌥ compose, as Terminal and iTerm do
/// (`Preferences.terminalOptionAsMeta`). These four keys compose nothing, so their word-wise meaning is put
/// back by hand and nothing is given up.
///
/// **⌘ plus a navigation key.** macOS means "to the end of the line" by these, and every shell spells that
/// `^A`, `^E`, `^U`, `^K`. Left alone, AppKit turns `⌘←` into `moveToLeftEndOfLine:`, which SwiftTerm sends
/// as *word back* — the same thing as `⌥←`, which is not what the key says — and `⌘⌫` reaches a selector it
/// does not handle at all, so nothing is sent.
public enum TerminalEditingKeys {
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
    public static func optionSequence(keyCode: UInt16) -> [UInt8]? {
        switch keyCode {
        case Code.leftArrow: [0x1b, 0x62]
        case Code.rightArrow: [0x1b, 0x66]
        case Code.backspace: [0x1b, 0x7f]
        case Code.forwardDelete: [0x1b, 0x64]
        default: nil
        }
    }

    /// The bytes ⌘ plus `keyCode` sends, or `nil` to leave the event alone.
    ///
    /// | Key | Sends | Means |
    /// |---|---|---|
    /// | ⌘← | `^A` | start of the line |
    /// | ⌘→ | `^E` | end of the line |
    /// | ⌘⌫ | `^U` | delete back to the start of the line |
    /// | ⌘⌦ | `^K` | delete to the end of the line |
    public static func commandSequence(keyCode: UInt16) -> [UInt8]? {
        switch keyCode {
        case Code.leftArrow: [0x01]
        case Code.rightArrow: [0x05]
        case Code.backspace: [0x15]
        case Code.forwardDelete: [0x0b]
        default: nil
        }
    }
}
