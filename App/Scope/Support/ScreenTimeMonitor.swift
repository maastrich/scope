import AppKit
import CoreGraphics
import ScopeCore

/// Tells `ScreenTimeClock` when the person can no longer be looking at Scope, and when they can again: the app
/// going to the background, its windows all hidden or covered, the session locking, the Mac sleeping, and the
/// keyboard and the mouse left alone for `ScreenTimeClock.idleThreshold`.
///
/// Idleness is polled rather than observed — there is no event for "nothing happened" — from
/// `CGEventSource.secondsSinceLastEventType`, which needs no permission. When it is noticed, the pause is dated back
/// to the last input, so the poll interval bounds nothing but how late the clock learns of it.
@MainActor
final class ScreenTimeMonitor {
    static let idlePollInterval: TimeInterval = 10

    private let onChange: (ScreenTimeClock.Blocker, Bool, Date) -> Void
    /// Kept for the life of the app, like the monitor itself: `Usage` holds the one instance and never lets it go.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var idle = false

    init(onChange: @escaping (ScreenTimeClock.Blocker, Bool, Date) -> Void) {
        self.onChange = onChange
    }

    func start() {
        onChange(.inactive, !NSApp.isActive, .now)
        onChange(.hidden, !Self.anyWindowVisible, .now)
        let app = NotificationCenter.default
        observe(app, NSApplication.didBecomeActiveNotification) { $0.onChange(.inactive, false, .now) }
        observe(app, NSApplication.didResignActiveNotification) { $0.onChange(.inactive, true, .now) }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            // After the notification, so a window closing or hiding is no longer among the visible ones.
            observe(app, name) { monitor in DispatchQueue.main.async { monitor.onChange(.hidden, !Self.anyWindowVisible, .now) } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.onChange(.asleep, true, .now) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.onChange(.asleep, false, .now) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.onChange(.asleep, true, .now) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.onChange(.asleep, false, .now) }
        // The lock screen has no public API; these are what loginwindow posts, used since macOS 10.x.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.onChange(.locked, true, .now) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.onChange(.locked, false, .now) }
        let timer = Timer(timeInterval: Self.idlePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIdle() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (ScreenTimeMonitor) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, observer))
    }

    /// Idleness has no event, and the window notifications can land before the first window exists: every poll also
    /// re-reads what is frontmost and what is visible, and the clock ignores what did not change.
    private func pollIdle() {
        onChange(.inactive, !NSApp.isActive, .now)
        onChange(.hidden, !Self.anyWindowVisible, .now)
        let seconds = Self.secondsSinceLastInput()
        if seconds >= ScreenTimeClock.idleThreshold, !idle {
            idle = true
            onChange(.idle, true, Date.now.addingTimeInterval(-seconds))
        } else if seconds < ScreenTimeClock.idleThreshold, idle {
            idle = false
            onChange(.idle, false, .now)
        }
    }

    /// Something of the app is on a screen: not hidden, not minimized, not fully covered, not on another Space.
    static var anyWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    /// Seconds since the person last touched the keyboard or the pointer, in any app.
    static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
