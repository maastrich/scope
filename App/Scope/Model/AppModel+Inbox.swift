import Foundation
import Observation
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeGit
import ScopeTasks

/// What the Inbox needs beyond `AppModel` (extended, not edited): the dismissals of task items, the selected row and
/// the row whose reply field is open. One for the app, shared by the sheet and the menu bar extra.
@MainActor
@Observable
final class InboxState {
    static let shared = InboxState()

    private(set) var dismissals = Inbox.Dismissals()
    /// The row the keyboard acts on (`Inbox.Item.id`).
    var selected: String?
    /// The thread item whose reply field is open; one at a time.
    var replyingTo: String?

    @ObservationIgnored private var store: InboxDismissalStore?

    /// Reads `<home>/inbox.json` once; later calls do nothing.
    func load(home: URL) {
        guard store == nil else { return }
        let store = InboxDismissalStore(home: home)
        self.store = store
        Task { dismissals = await store.load() }
    }

    func setDismissals(_ next: Inbox.Dismissals) {
        guard next != dismissals else { return }
        dismissals = next
        guard let store else { return }
        Task { await store.save(next) }
    }
}

/// The Inbox (spec §7): what needs the owner, in every scope, with an action at hand for each item. The list itself
/// is `Inbox` (ScopeKit); this is where the app's threads and tasks are put into its words and its actions land.
extension AppModel {
    var inbox: InboxState {
        let state = InboxState.shared
        state.load(home: env.home)
        return state
    }

    /// Every item, newest first. Recomputed from observed state (thread states, task records, pull requests): what
    /// is read from a thread's activity only words an item that a state change already put there.
    var inboxItems: [Inbox.Item] {
        Inbox.items(threads: threads.compactMap(inboxInput), tasks: tasks.map(inboxInput), schedules: inboxScheduleInputs,
                    dismissed: inbox.dismissals)
    }

    var inboxGroups: [Inbox.Group] {
        Inbox.groups(inboxItems, scopeOrder: scopes.map(\.id))
    }

    var inboxCount: Int { inboxItems.count }

    private func inboxInput(_ session: ThreadSession) -> Inbox.ThreadInput? {
        let state = session.displayState
        let stuck = state == .running ? session.assistNote?.stuckReason : nil
        guard state.needsAttention || state.isUnreadResult || stuck != nil else { return nil }
        let activity = session.activity
        let since = stuck != nil ? (session.assistNote?.at ?? .now)
            : activity.pendingRequest?.at ?? activity.turns.last?.endedAt ?? session.record.lastLaunchedAt ?? session.record.createdAt
        let text: String?
        if state == .failed {
            let code = session.lastFailure ?? activity.turns.last?.error
            text = ThreadNotificationContent.failureDescription(code).map { "Stopped on an error: \($0)" }
                ?? "Stopped on an error"
        } else {
            text = ThreadActivityHeadline.make(activity, state: state, finished: .reply).map { $0.reply ?? $0.text }
                ?? (activity.lastReply ?? session.lastReply)?.text
        }
        return Inbox.ThreadInput(id: session.id, scopeID: session.record.scopeID,
                                 taskID: session.record.taskID.flatMap(TaskID.init(rawValue:)),
                                 title: displayTitle(for: session), state: state, since: since, text: text, stuckReason: stuck)
    }

    private func inboxInput(_ task: TaskState) -> Inbox.TaskInput {
        Inbox.TaskInput(id: task.id, scopeID: task.scopeID, name: task.name, pullRequest: inboxPullRequest(task),
                        archivedAt: task.record.isArchived ? (task.record.archivedAt ?? task.record.createdAt) : nil,
                        isDismantling: task.isDismantling, attemptsKept: task.record.attemptsKept)
    }

    /// An open task's pull request as `gh` last saw it. An archived one is not asked again: its record keeps the state
    /// GitHub last answered, which is what tells a merge.
    private func inboxPullRequest(_ task: TaskState) -> Inbox.TaskInput.PullRequestInput? {
        if !task.record.isArchived, let pr = livePullRequest(for: task) {
            return .init(number: pr.number, title: pr.title, url: pr.url, state: pr.state, checks: pr.checks,
                         mergeable: pr.mergeable, isDraft: pr.isDraft,
                         failingChecks: pr.checkRuns.filter { $0.state == .failing }.map(\.title), updatedAt: pr.updatedAt)
        }
        guard let link = task.record.pullRequest else { return nil }
        return .init(number: link.number, title: link.title, url: link.url,
                     state: link.state.flatMap(PullRequest.State.init(rawValue:)) ?? .open, checks: .none,
                     mergeable: .unknown, updatedAt: task.record.archivedAt ?? task.record.createdAt)
    }

    // MARK: Actions

    func showInbox() {
        pruneInboxDismissals()
        globalSheet = .inbox
    }

    /// ↩: the thread on screen; a task item shows its task, an archived one comes back.
    func openInboxItem(_ item: Inbox.Item) {
        globalSheet = nil
        if let thread = item.threadID {
            reveal(thread: thread, showDelta: false)
            AppDelegate.refocusTerminal()
        } else if item.kind == .archivedOnMerge, let task = item.taskID {
            Task { await reopenTask(task) }
        } else if let task = item.taskID.flatMap(task) {
            switchToTask(task)
        }
    }

    /// e: a thread item is marked read (its state goes back to idle); a task item is dismissed until it changes.
    func markInboxItemRead(_ item: Inbox.Item) {
        if item.kind == .stuck, let thread = item.threadID {
            markNotStuck(thread)
        } else if let thread = item.threadID {
            markRead(thread)
            session(thread)?.acknowledgeResult()
        } else {
            var next = inbox.dismissals
            next.dismiss(item)
            inbox.setDismissals(next)
        }
    }

    /// Sends `text` the way the sidebar's reply does; `false` when nothing went.
    @discardableResult
    func replyFromInbox(_ text: String, to item: Inbox.Item) -> Bool {
        guard let thread = item.threadID else { return false }
        return sendMessage(text, to: thread)
    }

    /// A schedule's run: the thread's last reply in the reading column.
    func readInboxReply(_ item: Inbox.Item) {
        guard let thread = item.threadID, let session = session(thread) else { return }
        globalSheet = nil
        readReply(of: session)
    }

    func archiveInboxTask(_ item: Inbox.Item) {
        guard let task = item.taskID else { return }
        Task { await archiveTask(task) }
    }

    func restoreInboxTask(_ item: Inbox.Item) {
        guard let task = item.taskID else { return }
        Task { await reopenTask(task) }
    }

    func openInboxPullRequest(_ item: Inbox.Item) {
        guard let url = item.pullRequestURL else { return }
        openOnGitHub(url)
    }

    /// The thread a failing check goes to: the task's agent that worked last, else any of its threads.
    func checkFailureThread(for item: Inbox.Item) -> ThreadSession? {
        guard let task = item.taskID else { return nil }
        let sessions = threads(in: task)
        let agents = sessions.filter(\.deliversEvents)
        return (agents.isEmpty ? sessions : agents)
            .max { ($0.activity.turns.last?.endedAt ?? .distantPast) < ($1.activity.turns.last?.endedAt ?? .distantPast) }
    }

    /// s: every failing check of the item's pull request, to the task's thread (`sendCheckFailure`).
    func sendInboxCheckFailures(_ item: Inbox.Item) {
        guard let task = item.taskID.flatMap(task), let thread = checkFailureThread(for: item),
              let pr = livePullRequest(for: task) else { return }
        let failing = pr.checkRuns.filter { $0.state == .failing }
        Task {
            for check in failing { await sendCheckFailure(check, of: task, to: thread.id) }
        }
        messageUI.showSent("Sent \(failing.count == 1 ? "the failing check" : "\(failing.count) failing checks") to \(messageTargetName(thread.id))",
                           thread: thread.id)
    }

    /// Dismissals that no longer hide anything go, so the same failure after a green run is news again.
    func pruneInboxDismissals() {
        let candidates = Inbox.items(threads: [], tasks: tasks.map(inboxInput), schedules: inboxScheduleInputs)
        // An open task whose pull request was not read since launch has no item for want of knowing.
        let unread = Set(tasks.filter { !$0.record.isArchived && $0.record.pullRequest != nil && livePullRequest(for: $0) == nil }
            .map { "task:\($0.id.rawValue):pr" })
        inbox.setDismissals(inbox.dismissals.pruned(keeping: candidates, judged: { !unread.contains($0) }))
    }
}
