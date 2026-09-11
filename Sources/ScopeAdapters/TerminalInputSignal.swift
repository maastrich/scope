import Foundation

/// What the user's own keystrokes say about a thread's turn, for the moments no driver hook reports:
///
/// - Claude Code sends nothing when the user interrupts a turn (Esc, Ctrl-C): `Stop` does not fire, so the
///   thread would stay `running` until the next prompt. Nor does it say when a permission prompt is approved:
///   the next hook is the tool's `PostToolUse`, possibly minutes later.
/// - Codex's `notify` only reports the end of a turn, never its start.
public enum TerminalInputSignal: Equatable, Sendable {
    /// Esc on its own, or Ctrl-C: the user stops whatever the driver is doing.
    case interrupt
    /// Return. `hadText` is `true` when something was typed since the previous Return: a prompt, not an empty line.
    case submit(hadText: Bool)
}

/// Turns the chunks the terminal writes to the child into `TerminalInputSignal`s. A chunk is one key press or one
/// paste, as SwiftTerm hands it over, so a lone Esc is told apart from the escape sequence of an arrow key.
public struct TerminalInputTracker: Sendable {
    private var typedSinceSubmit = false

    public init() {}

    private static let escape: UInt8 = 0x1b
    private static let controlC: UInt8 = 0x03
    private static let carriageReturn: UInt8 = 0x0d
    private static let bracketedPasteStart = Array("\u{1b}[200~".utf8)

    public mutating func feed(_ bytes: some Collection<UInt8>) -> TerminalInputSignal? {
        if bytes.count == 1, bytes.first == Self.escape { return .interrupt }
        if bytes.contains(Self.controlC) {
            typedSinceSubmit = false
            return .interrupt
        }
        // Arrow keys, function keys, focus reports say nothing about the prompt; a bracketed paste is text.
        if bytes.first == Self.escape {
            if bytes.starts(with: Self.bracketedPasteStart) { typedSinceSubmit = true }
            return nil
        }
        var sawText = false
        for byte in bytes {
            if byte == Self.carriageReturn {
                let hadText = typedSinceSubmit || sawText
                typedSinceSubmit = false
                return .submit(hadText: hadText)
            }
            if byte >= 0x20, byte != 0x7f { sawText = true }
        }
        if sawText { typedSinceSubmit = true }
        return nil
    }
}
