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
    /// What the shape is doing, and the presentation it draws: both changed together inside one animation, so a new
    /// reveal's content and the outline's new size move as one (`IslandController.updateStage`).
    var stage: Island.Stage = .collapsed
    var presentation: Island.Presentation = .collapsed
}

/// The island's window: a borderless, non-activating `NSPanel` above every window, on every Space and over full-screen
/// apps, hung from the top of the chosen screen. It never takes the keyboard — a click on it must leave the app the
/// user is in where it was.
///
/// It never changes size either (`Island.panelSize`): the shape inside grows and folds on a spring, and a window resized
/// under it either cut that short or showed it a frame late. Outside the shape it ignores the mouse, so the menu bar and
/// the windows under it keep their clicks: the pointer is followed by event monitors — which need no permission for the
/// mouse — and the window takes events only while the pointer is on the shape (`Island.hitRect`). The same reading
/// drives the hover, so the island answers the hand the moment it arrives, wherever the shape is in its animation.
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
    private var hideTask: Task<Void, Never>?
    private var outsideClicks: Any?
    private var pointerMonitors: [Any] = []
    /// The shape's size as last laid out, and whether the pointer is on it.
    private var shapeSize: CGSize = .zero
    private var pointerInside = false
    #if DEBUG
    /// Set by `island-command` `peek`: the hand moving elsewhere does not take it back until `unpeek`.
    private var debugPinned = false
    #endif
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
        hideTask?.cancel()
        panel?.orderOut(nil)
        hiddenForFullScreen = false
        stopOutsideClicks()
        stopPointer()
        updateFollowing(false)
    }

    private func makePanel(model: AppModel) -> IslandPanel {
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Island.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
        // Over the menu bar, which is where the notch is, and under the menus and alerts. After `isFloatingPanel`,
        // which sets the level back to `.floating`.
        panel.isFloatingPanel = true
        #if DEBUG
        // A notch hosts one island: a Debug build's draws over the installed app's, which sits at `.statusBar`, so the
        // one being worked on is the one seen and hovered.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        #else
        panel.level = .statusBar
        #endif
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = IslandHostingView(rootView: AnyView(IslandView(layout: layout).environment(model)))
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
                self?.updateStage()
                self?.place()
                self?.track()
            }
        }
    }

    /// Moves the shape to what the model and the pointer say, on the spring that suits the move (`Island.spring`).
    private func updateStage() {
        guard let model else { return }
        let presentation = model.island.presentation
        let stage = Island.stage(presentation, hovering: pointerInside)
        guard stage != layout.stage || presentation != layout.presentation else { return }
        let spring = Island.spring(from: layout.stage, to: stage)
        let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: spring.response, dampingFraction: spring.damping)
        withAnimation(animation) {
            layout.stage = stage
            layout.presentation = presentation
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
        guard let model, let panel else { return }
        let settings = model.config.preferences.island
        let snapshot = model.island.snapshot
        if snapshot.isEmpty && model.island.presentation != .expanded {
            if model.island.presentation != .collapsed { model.island.presentation = .collapsed }
            hiddenForFullScreen = false
            updateFollowing(false)
            // After the fold, which the shape plays inside the window.
            if panel.isVisible, hideTask == nil {
                hideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self else { return }
                    self.hideTask = nil
                    if self.model?.island.snapshot.isEmpty == true { self.hide() }
                }
            }
            return
        }
        let all = screens().map(\.1)
        let front = settings.placement == .activeWindow || settings.hidesInFullScreen ? frontApp() : nil
        let activeWindow = settings.placement == .activeWindow ? front?.window : nil
        guard var target = Island.screen(all, settings: settings, pointer: NSEvent.mouseLocation,
                                         activeWindow: activeWindow) else { return }
        // Never pulled from under the user: while open or under the pointer it stays where it is.
        if panel.isVisible,
           model.island.presentation == .expanded || pointerInside,
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
            stopPointer()
            updateFollowing(following)
            return
        }
        hiddenForFullScreen = false
        let band = Island.band(on: target)
        let height = Island.collapsedHeight(on: target)
        if layout.bandWidth != band.width { layout.bandWidth = band.width }
        if layout.bandHeight != height { layout.bandHeight = height }
        // The one frame for every stage: set when the island changes screen, never for an animation.
        let frame = Island.panelFrame(on: target)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        hideTask?.cancel()
        if !panel.isVisible { panel.orderFrontRegardless() }
        startPointer()
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

    // MARK: The pointer

    /// The shape laid out at a new size: the pointer may be on it, or off it, without having moved.
    func shapeChanged(_ size: CGSize) {
        guard size != shapeSize else { return }
        shapeSize = size
        pointerMoved()
    }

    private func startPointer() {
        guard pointerMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Global: the pointer over other apps, the island ignoring the mouse. Local: over the island itself.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { pointerMonitors.append(local) }
        pointerMoved()
    }

    private func stopPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        if pointerInside {
            pointerInside = false
            model?.island.hovering = false
            hoverTask?.cancel()
        }
        panel?.ignoresMouseEvents = true
    }

    /// One rectangle test per mouse event; anything more happens only when the pointer crosses the shape's edge.
    private func pointerMoved(at point: CGPoint = NSEvent.mouseLocation) {
        guard let panel, panel.isVisible else { return }
        #if DEBUG
        if debugPinned { return }
        #endif
        let rect = Island.hitRect(shape: shapeSize, in: panel.frame, bandMidX: panel.frame.midX)
        let inside = Island.isOver(point, hitRect: rect, stage: layout.stage)
        guard inside != pointerInside else { return }
        pointerInside = inside
        panel.ignoresMouseEvents = !inside
        model?.island.hovering = inside
        updateStage()
        hovered(inside)
    }

    #if DEBUG
    /// `island-command` `peek` / `unpeek`: the pointer arriving or leaving, without the hand.
    func debugHover(_ inside: Bool) {
        debugPinned = inside
        pointerInside = inside
        model?.island.hovering = inside
        updateStage()
    }
    #endif

    // MARK: Opening

    private func hovered(_ inside: Bool) {
        guard let model else { return }
        hoverTask?.cancel()
        guard model.config.preferences.island.opening == .hover else { return }
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: inside ? Self.hoverDelay : Self.leaveDelay)
            guard !Task.isCancelled, let model = self?.model else { return }
            model.islandGesture(inside ? .pointerIn : .pointerOut)
        }
    }

    /// A click on the collapsed island, in either mode: the click mode's way in, and a shortcut past the hover delay.
    func toggle() {
        model?.islandGesture(.toggle)
    }

    /// While open, a click anywhere else closes it. A global monitor sees clicks meant for other apps without taking
    /// them; clicks on the island itself are local and never reach it.
    private func updateOutsideClicks(expanded: Bool) {
        if expanded, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model?.islandGesture(.clickOutside)
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
/// only woke the window.
final class IslandHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
