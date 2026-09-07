import AppKit
import SwiftUI

/// Hosts `ShortcutsView` in its own titled window (one instance, brought to front on every call).
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: ShortcutsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ShortcutsWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}
