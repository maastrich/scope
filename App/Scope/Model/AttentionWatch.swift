import AppKit
import ScopeTasks

/// Whether anyone is likely looking at Scope, for the pull request refresh (`PullRequestRefreshSchedule.Attention`),
/// and whether the Mac is asleep. The lock screen, sleep and display sleep come as notifications; being frontmost and
/// the time since the last input are read when asked.
@MainActor
final class AttentionWatch {
    private(set) var asleep = false
    private(set) var locked = false
    private(set) var displaysAsleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var attention: PullRequestRefreshSchedule.Attention {
        .resolve(frontmost: NSApp.isActive, locked: locked, displaysAsleep: displaysAsleep,
                 idleSeconds: ScreenTimeMonitor.secondsSinceLastInput())
    }

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        // What loginwindow posts; the lock screen has no public API (`ScreenTimeMonitor` reads the same pair).
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (AttentionWatch) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, observer))
    }
}
