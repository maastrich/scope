import AppKit
import SwiftUI

/// The quick panel's window: a floating, borderless `NSPanel` that takes the keyboard without activating the app —
/// the hotkey is pressed over another app's window, and that window must still be there, unmoved, when the panel
/// goes. Centred on the screen the pointer is on, a third of the way down, where a launcher sits.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickPanelController()

    private var panel: QuickPanelWindow?
    private var monitor: Any?

    var isShown: Bool { panel?.isVisible == true }

    func show(model: AppModel) {
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        place(panel)
        installMonitor(model: model)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func makePanel(model: AppModel) -> QuickPanelWindow {
        let panel = QuickPanelWindow(contentRect: NSRect(x: 0, y: 0, width: QuickPanelView.width, height: 300),
                                     styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        let host = NSHostingView(rootView: QuickPanelView().environment(model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    /// Where the pointer is, not where the key window is: the user looks at the screen they are working on.
    private func place(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.28 - size.height)
        panel.setFrameOrigin(origin)
    }

    /// Esc closes, ⌃1…⌃9 pick the scope — taken before the views and the main menu, whichever has the keyboard
    /// inside the panel. Only events of this window: the monitor is local to the app, the panel is the one window
    /// taking keys while it is up.
    private func installMonitor(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty {
                MainActor.assumeIsolated { model.hideQuickPanel() }
                return nil
            }
            if flags == .control, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                MainActor.assumeIsolated { model.chooseQuickPanelScope(digit: digit) }
                return nil
            }
            return event
        }
    }

    // MARK: NSWindowDelegate

    /// A click anywhere else is a dismissal, as it is for a launcher.
    func windowDidResignKey(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        // The reply field of an Inbox row is in the same window; a popover or a menu of ours is not a dismissal either.
        if let key = NSApp.keyWindow, key.parent === panel { return }
        AppServices.model?.hideQuickPanel()
    }
}

/// A borderless panel does not take the keyboard unless told it may.
final class QuickPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
