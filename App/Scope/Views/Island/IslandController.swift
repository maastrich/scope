import AppKit
import ScopeControl
import ScopeCore
import SwiftUI

/// Where the island's shape stands on its screen, for the view: around a notch, or as a capsule where there is none.
@MainActor
@Observable
final class IslandLayout {
    /// The notch's width; 0 on a screen without one.
    var bandWidth: CGFloat = 0
    /// The collapsed height: the notch's, or a few points short of the menu bar (`Island.collapsedHeight`).
    var bandHeight: CGFloat = 20
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
    /// Put away over a full-screen app, and looked at again by the follow timer until that app leaves full screen.
    private var hiddenForFullScreen = false

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
        hiddenForFullScreen = false
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
                guard let self, let island = self.model?.config.preferences.island,
                      island.placement == .activeWindow || island.hidesInFullScreen else { return }
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
            hiddenForFullScreen = false
            updateFollowing(false)
            return
        }
        let all = screens().map(\.1)
        let front = settings.placement == .activeWindow || settings.hidesInFullScreen ? frontApp() : nil
        let activeWindow = settings.placement == .activeWindow ? front?.window : nil
        guard var target = Island.screen(all, settings: settings, pointer: NSEvent.mouseLocation,
                                         activeWindow: activeWindow) else { return }
        // Never pulled from under the user: while open or under the pointer it stays where it is.
        if panel.isVisible,
           model.island.presentation == .expanded || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false),
           let current = all.first(where: { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 1)) }) {
            target = current
        }
        // Over a video, a talk or an editor in full screen the island is in the way: only an agent waiting on the user,
        // or the island the user opened, still shows there.
        let following = settings.placement == .pointer || settings.placement == .activeWindow || settings.hidesInFullScreen
        var revealing: Island.AlertKind?
        if case .alert(let alert) = model.island.presentation { revealing = alert.kind }
        if Island.hidesForFullScreen(settings: settings, frontWindows: front?.all ?? [], on: target,
                                     isOpen: model.island.presentation == .expanded, hasRequests: !snapshot.requests.isEmpty,
                                     revealing: revealing) {
            panel.orderOut(nil)
            hiddenForFullScreen = true
            stopOutsideClicks()
            updateFollowing(following)
            return
        }
        hiddenForFullScreen = false
        let band = Island.band(on: target)
        let height = Island.collapsedHeight(on: target)
        if layout.bandWidth != band.width { layout.bandWidth = band.width }
        if layout.bandHeight != height { layout.bandHeight = height }
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
        updateFollowing(following)
    }

    /// The screen under the pointer, or the active window's as it is dragged to another screen within the same app,
    /// and whether an app went in or out of full screen, followed while the island shows or is put away for full
    /// screen. Two seconds is soon enough to change screens and cheap on energy (the window list is not free); a change
    /// of app comes at once, through the activation notification.
    private func updateFollowing(_ follows: Bool) {
        if follows, followTimer == nil {
            followTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible || self.hiddenForFullScreen else { return }
                    self.place()
                }
            }
            followTimer?.tolerance = 0.5
        } else if !follows {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    /// The active app's windows, in AppKit's coordinates: its frontmost window (`nil` when it shows none) and all its
    /// document windows, for full screen. Scope's own main window when Scope is in front. The window list's owner,
    /// layer and bounds need no permission — only the titles take Screen Recording — and the island, a panel above
    /// layer 0, is never taken for a window.
    private func frontApp() -> (window: CGRect?, all: [CGRect])? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let all = NSApp.windows.filter { $0.isVisible && $0.level == .normal && !($0 is IslandPanel) }.map(\.frame)
            let main = (NSApp.mainWindow ?? NSApp.keyWindow).flatMap { $0.isVisible && !($0 is IslandPanel) ? $0.frame : nil }
            return (main ?? all.first, all)
        }
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let windows = list.compactMap(Island.WindowInfo.init)
        let flip = { Island.appKitRect(fromQuartz: $0, primaryHeight: primary.frame.height) }
        return (Island.frontWindow(of: app.processIdentifier, in: windows).map(flip),
                Island.documentWindows(of: app.processIdentifier, in: windows).map(flip))
    }

    // MARK: Opening

    private func hovered(_ inside: Bool) {
        guard let model else { return }
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
