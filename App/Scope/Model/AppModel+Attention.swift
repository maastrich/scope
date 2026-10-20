import AppKit
import ScopeAdapters
import ScopeAssist
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

    /// Mark as Read: the user has seen what the thread is asking (or what it finished with) and does not want it
    /// counted any more — the badge, the sidebar mark and the notification go. Read is not muted: the next question
    /// the driver asks brings the attention straight back (see `ThreadState.acknowledged`).
    func markRead(_ id: ThreadID) {
        guard let session = session(id), session.displayState.acknowledged != session.displayState else { return }
        session.acknowledgeAttention()
        clearNotifications(for: id)
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

    /// Re-evaluates the Dock badge whenever any thread state it depends on changes. A base checkout on a task's
    /// branch shows as `try` while nothing waits: the one state of the base worth a glance at the Dock.
    func startBadgeTracking() {
        withObservationTracking {
            let count = waitingThreads.count
            let trying = !tryingTasks.isEmpty
            NSApplication.shared.dockTile.badgeLabel = count == 0 ? (trying ? "try" : nil) : String(count)
        } onChange: {
            Task { @MainActor [weak self] in self?.startBadgeTracking() }
        }
    }

    /// Posts a notification for `event` on `session` when the app is in the background. `session` has already
    /// folded `event` in, so its state is the one after it. `triage` is what the assistant made of the agent's words,
    /// when it was asked (spec §4.10): a finished turn it reads as informational stays silent when the preference says.
    func notifyIfNeeded(_ event: AdapterEvent, session: ThreadSession, triage: NotificationTriage? = nil) {
        // Posting would replace the question's notification, quote and Reply with it, by "asks for a permission".
        if let state = session.adapterState, ThreadStateMachine.keepsQuestion(state, over: event) { return }
        if event.kind == .turnEnded, let triage, !triage.interrupts, config.preferences.assistQuietsInformational {
            Usage.record(.assist, "assist.triage.quieted", source: .app)
            return
        }
        let kind: HookEvent.Kind = event.kind == .inputRequested && event.reason == "permission" ? .permissionRequested : event.kind
        guard let stateEvent = kind.stateEvent,
              ThreadNotificationContent.shouldNotify(event: stateEvent, appIsActive: NSApplication.shared.isActive),
              let scope = scope(session.record.scopeID),
              let content = ThreadNotificationContent.make(event: stateEvent, driver: session.profile.name,
                                                           scope: scope.name, task: task(of: session)?.name,
                                                           failure: event.payload[HookEvent.errorKey],
                                                           said: config.preferences.notificationsQuoteAgent
                                                               ? .from(event, activity: session.activity,
                                                                       pending: session.claude.pending.current) : nil)
        else { return }
        // Said already, from `claude agents`, before `permission_prompt` came.
        let asked = kind == .permissionRequested ? session.claude.pending.current : nil
        if let asked, session.notifiedRequestID == asked.id { return }
        // A permission Scope can answer gets Allow / Deny instead of a Reply, whose ↩ would pick the dialog's
        // highlighted Yes. Allow only when the banner shows the whole command.
        if let request = asked, request.kind == .permission, ClaudeDialogAnswer.isAnswerable(request) {
            let whole = request.command.map { !content.body.hasSuffix("…") && !$0.contains("\n") } ?? true
            notifier.post(content, threadID: session.id, permission: request.id, allows: whole)
            session.notifiedRequestID = request.id
            return
        }
        if let asked { session.notifiedRequestID = asked.id }
        // A finished turn the assistant read as blocking gets a *Not blocking* answer on its notification.
        notifier.post(content, threadID: session.id, triaged: event.kind == .turnEnded && triage?.interrupts == true)
    }

    /// The thread on screen is being looked at: a turn it finished is no longer news (`ThreadSession.acknowledgeResult`).
    /// Called when an event lands, when the selection changes and when the app comes back to the front.
    func acknowledgeShownResult() {
        guard NSApplication.shared.isActive, let id = selectedThreadID else { return }
        session(id)?.acknowledgeResult()
    }

    /// Coming back to the app is looking at the thread it shows.
    func startActivationTracking() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.acknowledgeShownResult() }
        }
    }

    /// A click on the notification (or its actions): brings the app up and shows the thread.
    func reveal(thread id: ThreadID, showDelta: Bool) {
        NSApp.activate()
        if session(id) != nil {
            selection = .thread(id)
            selectedThreadID = id
        }
        if showDelta {
            showInspector(.delta)
        }
    }

    /// A `scope://thread?…` link: brings the app up on the thread it names. A link that matches nothing still
    /// brings the window up, which is what the click did before the link existed.
    func open(_ link: ThreadLink) {
        let candidates = threads.map { ThreadLink.Candidate(id: $0.id, sessionID: $0.record.resumeID, pid: $0.pid) }
        guard let id = link.resolve(candidates) else {
            Log.threads.notice("thread link matched nothing: session \(link.sessionID ?? "-", privacy: .public) pid \(link.pid.map(String.init) ?? "-", privacy: .public)")
            NSApp.activate()
            return
        }
        Log.threads.notice("thread link → \(id.rawValue, privacy: .public)")
        reveal(thread: id, showDelta: false)
        AppDelegate.refocusTerminal()
    }

    /// A click on one of this app's cards in Vibe Island selects that thread (see `VibeIslandJump` for why this
    /// reads Vibe Island's log rather than waiting for a link).
    func startFollowingVibeIsland() {
        guard vibeIslandJumps == nil else { return }
        let watcher = VibeIslandJumpWatcher { [weak self] jump in self?.follow(jump) }
        watcher.start()
        vibeIslandJumps = watcher
    }

    /// Unlike a link, a jump that matches nothing is not for this app — another app's session, or a thread of
    /// another running Scope reading the same log — so it changes nothing.
    func follow(_ jump: VibeIslandJump) {
        let candidates = threads.map { ThreadLink.Candidate(id: $0.id, sessionID: $0.record.resumeID, pid: $0.pid) }
        guard let id = jump.resolve(candidates) else { return }
        Log.threads.notice("Vibe Island jump → \(id.rawValue, privacy: .public) (session \(jump.sessionPrefix ?? "-", privacy: .public), pid \(jump.pid.map(String.init) ?? "-", privacy: .public))")
        reveal(thread: id, showDelta: false)
        AppDelegate.refocusTerminal()
    }

    /// Pending notifications about the thread the user is looking at are stale.
    func clearNotifications(for id: ThreadID?) {
        guard let id else { return }
        notifier.clear(threadID: id)
    }
}
