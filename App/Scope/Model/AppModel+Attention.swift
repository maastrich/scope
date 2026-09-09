import AppKit
import ScopeAdapters
import ScopeCore

/// Everything that pulls the user back to a thread (spec §4.7): notifications when the app is not frontmost,
/// the Dock badge with the number of waiting threads, and the menu bar extra's list.
extension AppModel {
    /// Threads currently waiting for input or a permission, creation order.
    var waitingThreads: [ThreadSession] {
        threads.filter { $0.displayState.needsAttention }
    }

    /// The waiting threads of the scope the sidebar shows, which is what its banner counts.
    var waitingThreadsInCurrentScope: [ThreadSession] {
        guard let id = currentScopeID else { return [] }
        return waitingThreads.filter { $0.record.scopeID == id }
    }

    /// ⌥⌘↩: selects the next thread that wants the user and hands it the keyboard, wrapping around and crossing
    /// into another scope when the current one has nothing waiting.
    func revealNextWaitingThread() {
        let waiting = waitingThreads
        guard !waiting.isEmpty else { return }
        // Prefer the current scope, so the shortcut does not throw the sidebar somewhere else while work is left
        // here; fall back to any scope once this one is answered.
        let candidates = waitingThreadsInCurrentScope.isEmpty ? waiting : waitingThreadsInCurrentScope
        let next: ThreadSession
        if let current = selectedThreadID, let index = candidates.firstIndex(where: { $0.id == current }) {
            next = candidates[(index + 1) % candidates.count]
        } else {
            next = candidates[0]
        }
        reveal(thread: next.id, showDelta: false)
    }

    /// Re-evaluates the Dock badge whenever any thread state it depends on changes.
    func startBadgeTracking() {
        withObservationTracking {
            let count = waitingThreads.count
            NSApplication.shared.dockTile.badgeLabel = count == 0 ? nil : String(count)
        } onChange: {
            Task { @MainActor [weak self] in self?.startBadgeTracking() }
        }
    }

    /// Posts a notification for `event` on `session` when the app is in the background.
    func notifyIfNeeded(_ event: AdapterEvent, session: ThreadSession) {
        let kind: HookEvent.Kind = event.kind == .inputRequested && event.reason == "permission" ? .permissionRequested : event.kind
        guard let stateEvent = kind.stateEvent,
              ThreadNotificationContent.shouldNotify(event: stateEvent, appIsActive: NSApplication.shared.isActive),
              let scope = scope(session.record.scopeID),
              let content = ThreadNotificationContent.make(event: stateEvent, driver: session.profile.name,
                                                           scope: scope.name, task: task(of: session)?.name)
        else { return }
        notifier.post(content, threadID: session.id)
    }

    /// A click on the notification (or its actions): brings the app up and shows the thread.
    func reveal(thread id: ThreadID, showDelta: Bool) {
        NSApp.activate()
        if session(id) != nil {
            selection = .thread(id)
            selectedThreadID = id
        }
        if showDelta {
            inspectorTab = .delta
            inspectorShown = true
        }
    }

    /// Pending notifications about the thread the user is looking at are stale.
    func clearNotifications(for id: ThreadID?) {
        guard let id else { return }
        notifier.clear(threadID: id)
    }
}
