import AppKit
import ScopeControl
import ScopeCore
import SwiftUI

/// Where the island's shape stands on its screen, for the view: around a notch, or as a pill where there is none.
@MainActor
@Observable
final class IslandLayout {
    /// The notch's width; 0 on a screen without one.
    var bandWidth: CGFloat = 0
    /// The notch's height, or the menu bar's.
    var bandHeight: CGFloat = Island.pillHeight
    var onNotch: Bool { bandWidth > 0 }
}

/// The island's window: a borderless, non-activating `NSPanel` above every window, on every Space and over full-screen
/// apps, hung from the top of the chosen screen. It never takes the keyboard — a click on it must leave the app the
/// user is in where it was — and it is exactly as large as what it draws, so the menu bar and the windows under it
/// keep their clicks.
@MainActor
final class IslandController: NSObject {
    static let shared = IslandController()

    /// How long the pointer rests on the collapsed island before it opens, and stays away before it closes.
    static let hoverDelay: Duration = .milliseconds(150)
    static let leaveDelay: Duration = .milliseconds(350)

    private var panel: IslandPanel?
    private var host: IslandHostingView?
    let layout = IslandLayout()
    private weak var model: AppModel?
    private var hoverTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var outsideClicks: Any?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var followTimer: Timer?
    private var tracking = false
    private var hovering = false

    /// Puts the island up, or keeps it up, for what the model holds now.
    func show(model: AppModel) {
        self.model = model
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        if !tracking {
            tracking = true
            track()
        }
        place()
    }

    func hide() {
        panel?.orderOut(nil)
        stopOutsideClicks()
        updateFollowing(false)
    }

    private func makePanel(model: AppModel) -> IslandPanel {
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: Island.pillHeight),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
        // Over the menu bar, which is where the notch is, and under the menus and alerts. After `isFloatingPanel`,
        // which sets the level back to `.floating`.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = IslandHostingView(rootView: AnyView(IslandView(layout: layout).environment(model)))
        host.onHover = { [weak self] inside in self?.hovered(inside) }
        // The hosting view paints a faint ground of its own: the window's bounds would show around the shape.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        self.host = host
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // Posted on the workspace's own centre only.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.config.preferences.island.placement == .activeWindow else { return }
                self.place()
            }
        }
        return panel
    }

    /// Re-places the panel whenever what it draws or how it stands changes.
    private func track() {
        guard let model else { return }
        withObservationTracking {
            _ = model.island.snapshot
            _ = model.island.presentation
            _ = model.island.refusal?.text
            _ = model.config.preferences.island
        } onChange: {
            Task { @MainActor [weak self] in
                self?.place()
                self?.track()
            }
        }
    }

    // MARK: Placement

    private func screens() -> [(NSScreen, Island.Screen)] {
        let main = NSScreen.screens.first
        return NSScreen.screens.map { screen in
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            return (screen, Island.Screen(name: screen.localizedName, frame: screen.frame, safeTop: screen.safeAreaInsets.top,
                                          auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
                                          menuBarHeight: menuBar, isMain: screen == main))
        }
    }

    private func place() {
        guard let model, let panel, let host else { return }
        let settings = model.config.preferences.island
        let snapshot = model.island.snapshot
        if snapshot.isEmpty && model.island.presentation != .expanded {
            if model.island.presentation != .collapsed { model.island.presentation = .collapsed }
            panel.orderOut(nil)
            updateFollowing(false)
            return
        }
        let all = screens().map(\.1)
        let activeWindow = settings.placement == .activeWindow ? activeWindowFrame() : nil
        guard var target = Island.screen(all, settings: settings, pointer: NSEvent.mouseLocation,
                                         activeWindow: activeWindow) else { return }
        // Never pulled from under the user: while open or under the pointer it stays where it is.
        if panel.isVisible, hovering || model.island.presentation == .expanded,
           let current = all.first(where: { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 1)) }) {
            target = current
        }
        let band = Island.band(on: target)
        if layout.bandWidth != band.width { layout.bandWidth = band.width }
        if layout.bandHeight != band.height { layout.bandHeight = band.height }
        host.layoutSubtreeIfNeeded()
        let frame = Island.frame(for: host.fittingSize, on: target)
        // Growing at once and shrinking once the content has folded, so the window never cuts the animation short. Both
        // frames hang from the same top edge, centred on the same band: the content, pinned to the top, does not move.
        shrinkTask?.cancel()
        if panel.isVisible, panel.frame != frame, panel.frame.maxY == frame.maxY, target.frame.contains(panel.frame) {
            panel.setFrame(frame.union(panel.frame), display: true)
            shrinkTask = Task { @MainActor [weak panel] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                panel?.setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        updateOutsideClicks(expanded: model.island.presentation == .expanded)
        updateFollowing(settings.placement == .pointer || settings.placement == .activeWindow)
    }

    /// The screen under the pointer, or the active window's as it is dragged to another screen within the same app,
    /// followed while the island shows; a second is soon enough to change screens. A change of app comes at once,
    /// through the activation notification.
    private func updateFollowing(_ follows: Bool) {
        if follows, followTimer == nil {
            followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    self.place()
                }
            }
            followTimer?.tolerance = 0.3
        } else if !follows {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    /// The frontmost window of the active app, in AppKit's coordinates; `nil` when that app shows none. Scope's own
    /// main window when Scope is in front. The window list's owner, layer and bounds need no permission — only the
    /// titles take Screen Recording — and the island, a panel above layer 0, is never taken for the window.
    private func activeWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let window = NSApp.mainWindow ?? NSApp.keyWindow, window.isVisible, !(window is IslandPanel) {
            return window.frame
        }
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let windows = list.compactMap(Island.WindowInfo.init)
        guard let quartz = Island.frontWindow(of: app.processIdentifier, in: windows) else { return nil }
        return Island.appKitRect(fromQuartz: quartz, primaryHeight: primary.frame.height)
    }

    // MARK: Opening

    private func hovered(_ inside: Bool) {
        guard let model else { return }
        hovering = inside
        hoverTask?.cancel()
        guard model.config.preferences.island.opening == .hover else { return }
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: inside ? Self.hoverDelay : Self.leaveDelay)
            guard !Task.isCancelled, let self, let model = self.model else { return }
            if inside {
                model.island.presentation = .expanded
            } else if model.island.presentation == .expanded {
                model.island.presentation = .collapsed
            }
        }
    }

    /// A click on the collapsed island, in either mode: the click mode's way in, and a shortcut past the hover delay.
    func toggle() {
        guard let model else { return }
        model.island.presentation = model.island.presentation == .expanded ? .collapsed : .expanded
    }

    /// While open, a click anywhere else closes it. A global monitor sees clicks meant for other apps without taking
    /// them; clicks on the island itself are local and never reach it.
    private func updateOutsideClicks(expanded: Bool) {
        if expanded, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self?.model, model.island.presentation == .expanded else { return }
                    model.island.presentation = .collapsed
                }
            }
        } else if !expanded {
            stopOutsideClicks()
        }
    }

    private func stopOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
}

/// Never key, never main: the island answers clicks and leaves the keyboard where it was.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click — the panel is never key, and without this the first click on a button
/// only woke the window — and reports the pointer coming in and going, whatever app is active.
final class IslandHostingView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
