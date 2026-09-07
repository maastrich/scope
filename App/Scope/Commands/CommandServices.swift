import AppKit
import SwiftUI

/// AppKit-level actions shared by the menu bar and the command palette, plus the services the palette needs
/// but cannot reach through `AppModel` (the Sparkle updater lives with `ScopeApp`).
@MainActor
enum CommandServices {
    /// Set by `ScopeCommands` so "Check for Updates…" is reachable from the palette.
    static weak var updater: UpdaterController?

    /// `NSSplitViewController.toggleSidebar` through the responder chain (the View menu's ⌃⌘S).
    static func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    /// The SwiftUI `Settings` scene (⌘,).
    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// ⇧⌘W: closes the key window (the main window hides; ⌘W stays "Close Thread").
    static func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    /// Sends an `NSTextFinder` action to the first responder. SwiftTerm's terminal view implements
    /// `performTextFinderAction(_:)` and reads the action from the sender's `tag`, so the sender is a menu
    /// item carrying it. When the terminal is not first responder nothing responds and this is a no-op.
    static func textFinder(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}
