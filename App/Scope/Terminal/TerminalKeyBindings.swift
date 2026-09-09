import AppKit
import SwiftTerm

/// Key bindings the drivers expect and that never reach the terminal on their own.
///
/// `⌘↩` is the one that matters: AppKit routes a ⌘-modified key to `interpretKeyEvents`, which drops it, so
/// the agent never sees the keystroke. SwiftTerm's `keyDown` is `public`, not `open`, so it cannot be
/// overridden from here — a local event monitor takes the event before the view does instead, and only when
/// a terminal holds the keyboard.
///
/// What goes down the pty is **meta ↩**: `ESC CR` on a legacy terminal, `CSI 13;3u` once the app has asked
/// for the Kitty keyboard protocol. That is the sequence Claude Code and friends read as "newline, do not
/// submit".
@MainActor
enum TerminalKeyBindings {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        // The event's own values are read here (an `NSEvent` cannot cross into the isolated closure); the
        // monitor already runs on the main thread, so the hop only states what is true.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isCommandReturn(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
            return MainActor.assumeIsolated { sendMetaReturnToFocusedTerminal() } ? nil : event
        }
    }

    /// ⌘↩ alone (⌃ or ⌥ added means the user is after some other sequence; ⇧ is harmless).
    private nonisolated static func isCommandReturn(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return keyCode == 36
            && flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }

    /// `false` when no terminal holds the keyboard — the event then goes on its way (⌘↩ of a dialog, say).
    private static func sendMetaReturnToFocusedTerminal() -> Bool {
        guard let terminal = focusedTerminal else { return false }
        if terminal.getTerminal().keyboardEnhancementFlags.isEmpty {
            terminal.send([0x1b, 0x0d])
        } else {
            // Kitty modifier encoding: 1 + alt(2). Enter is functional key 13.
            terminal.send(txt: "\u{1b}[13;3u")
        }
        return true
    }

    /// The terminal under the keyboard: the responder chain is walked rather than the first responder cast,
    /// since SwiftTerm can park focus on a subview of its own (the search field).
    private static var focusedTerminal: TerminalView? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let terminal = current as? TerminalView { return terminal }
            responder = current.nextResponder
        }
        return nil
    }
}
