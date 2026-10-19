import AppKit
import ScopeAdapters
import ScopeCore
import ScopeGit
import ScopeTasks

/// The strip "Since 11:40 — 2 turns finished · 1 question for you · …" at the top of the sidebar (`ReturnDigest`).
///
/// A scope is *looked at* while it is the current one and the app is in front. When that stops — another scope is
/// picked, the app goes to the back, the app quits — its visit is stamped in `<home>/scope-visits.json` with the
/// state of its tasks' pull requests. Coming back — picking it again, or bringing the app back after
/// `returnDigestAwayMinutes` — measures what moved against that stamp.
@MainActor
@Observable
final class ReturnDigestModel {
    struct Shown: Equatable {
        let scopeID: ScopeID
        let digest: ReturnDigest
        /// One per return: a fresher digest of the same return keeps the strip's timer and baseline.
        let returnID: UUID
    }

    private(set) var shown: Shown?

    @ObservationIgnored var visits = ScopeVisits()
    @ObservationIgnored var store: ScopeVisitStore?
    /// When the app last went to the back.
    @ObservationIgnored var resignedAt: Date?
    /// The return being measured, so a pull request refresh that lands late updates that one and no other.
    @ObservationIgnored var pendingReturn: (scopeID: ScopeID, visit: ScopeVisits.Visit, id: UUID)?
    /// When `gh` was last asked about each task on a return: switching back and forth must not ask it every time.
    @ObservationIgnored var askedGitHub: [TaskID: Date] = [:]

    func show(_ shown: Shown?) {
        if self.shown != shown { self.shown = shown }
    }

    /// The strip's ×, a fragment clicked, the first selection change, or ten seconds on screen.
    func dismiss() {
        shown = nil
        pendingReturn = nil
    }
}

extension AppModel {
    /// A pull request asked about on a return is not asked again for this long.
    static let returnDigestGitHubInterval: TimeInterval = 120

    /// Loads the visits and follows the app going to the back and coming to the front. At launch the app is coming
    /// back from wherever it was when it quit, so that counts as a return too.
    func startReturnTracking() {
        let model = returnDigests
        let store = ScopeVisitStore(home: env.home)
        model.store = store
        model.visits = store.load()
        model.visits.retain(Set(scopes.map(\.id)))
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.returnDigests.resignedAt = .now
                if let id = self.currentScopeID { self.stampVisit(id) }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let away = self.returnDigests.resignedAt.map { Date.now.timeIntervalSince($0) } ?? 0
                self.returnDigests.resignedAt = nil
                guard away >= self.returnDigestAwayThreshold, let id = self.currentScopeID else { return }
                self.returnTo(id)
            }
        }
        if let id = currentScopeID, let last = model.visits[id]?.lastSeen,
           Date.now.timeIntervalSince(last) >= returnDigestAwayThreshold {
            returnTo(id)
        }
    }

    private var returnDigestAwayThreshold: TimeInterval {
        TimeInterval(config.preferences.returnDigestAwayMinutes * 60)
    }

    /// `currentScopeID` moved from `old` to `new`: `old` stops being looked at, `new` is returned to.
    func scopeSwitched(from old: ScopeID?, to new: ScopeID?) {
        if let old, isLooking { stampVisit(old) }
        if returnDigests.shown?.scopeID != new { returnDigests.dismiss() }
        if let new { returnTo(new) }
    }

    /// Quitting is leaving the scope on screen.
    func stampCurrentVisit() {
        if let id = currentScopeID, isLooking { stampVisit(id) }
    }

    /// The owner sees the window. A notification click switches scope before the app is active again, and a quit
    /// from the Dock happens in the back: the stamp taken when the app went to the back is the one that holds.
    private var isLooking: Bool {
        NSApplication.shared.isActive && returnDigests.resignedAt == nil
    }

    /// Writes `id`'s visit as ending now, with its tasks' pull requests as they are.
    private func stampVisit(_ id: ScopeID) {
        guard let store = returnDigests.store else { return }
        var seen: [TaskID: [PullRequestSnapshot]] = [:]
        for task in tasks(in: id) {
            let snapshots = pullRequestSnapshots(task)
            if !snapshots.isEmpty { seen[task.id] = snapshots }
        }
        returnDigests.visits[id] = .init(lastSeen: .now, pullRequests: seen)
        store.save(returnDigests.visits)
    }

    /// What is known of each of the task's pull requests: the last `gh` answer when there was one, the record otherwise.
    private func pullRequestSnapshots(_ task: TaskState) -> [PullRequestSnapshot] {
        task.record.pullRequests.map { link in
            if let live = pullRequests.taskPullRequest(link.url, for: task.id) {
                return PullRequestSnapshot(number: live.number, url: live.url, state: live.state, checks: live.checks)
            }
            return PullRequestSnapshot(number: link.number, url: link.url,
                                       state: link.state.flatMap(PullRequest.State.init(rawValue:)) ?? .open)
        }
    }

    /// Measures what moved in `id` since its last visit and shows it; then asks GitHub about the open pull requests
    /// and measures again, since a merge or a failing check is only known once asked.
    private func returnTo(_ id: ScopeID) {
        guard config.preferences.showReturnDigest, let visit = returnDigests.visits[id] else { return }
        let returnID = UUID()
        // The visit as it is now: a stamp taken while GitHub is being asked must not become the baseline.
        returnDigests.pendingReturn = (id, visit, returnID)
        Task { [weak self] in
            guard let self else { return }
            await self.measureReturn(returnID)
            guard await self.askGitHub(about: id) else { return }
            await self.measureReturn(returnID)
        }
    }

    private func measureReturn(_ returnID: UUID) async {
        guard let pending = returnDigests.pendingReturn, pending.id == returnID else { return }
        let seen = pending.visit.seenPullRequests
        let threads = await threadFacts(in: pending.scopeID)
        // Archived tasks count only if they were live when the owner left: auto-archiving on merge must not hide
        // the merge, and a task archived long ago is not news.
        let tasks = tasks.filter { $0.scopeID == pending.scopeID && (!$0.isArchived || seen[$0.id] != nil) }.map {
            ReturnDigest.TaskFacts(id: $0.id, name: $0.name, isArchived: $0.isArchived, pullRequests: pullRequestSnapshots($0))
        }
        // The owner may have moved on while the activity was read.
        guard returnDigests.pendingReturn?.id == returnID, currentScopeID == pending.scopeID else { return }
        guard let digest = ReturnDigest.make(since: pending.visit.lastSeen, threads: threads, tasks: tasks, seen: seen) else { return }
        returnDigests.show(.init(scopeID: pending.scopeID, digest: digest, returnID: returnID))
    }

    /// Each thread's turns and wait. A thread restored at launch may not have read its saved activity back yet: the
    /// store has it.
    private func threadFacts(in scope: ScopeID) async -> [ReturnDigest.ThreadFacts] {
        var facts: [ReturnDigest.ThreadFacts] = []
        for session in threads(in: scope) {
            var activity = session.activity
            if activity.turns.isEmpty, let saved = await env.threadActivity.load(session.id) { activity = saved }
            let waiting = session.displayState.needsAttention
                ? activity.turns.last(where: { $0.outcome.isWait })?.endedAt ?? activity.pendingRequest?.at
                : nil
            facts.append(ReturnDigest.ThreadFacts(
                id: session.id,
                finishedTurns: activity.turns.filter { $0.outcome == .ended }.map(\.endedAt),
                failedTurns: activity.turns.filter { $0.outcome == .failed }.map(\.endedAt),
                waitingSince: waiting))
        }
        return facts
    }

    /// `gh pr view` for the open pull requests of `scope` not asked about lately. `true` when any was asked.
    private func askGitHub(about scope: ScopeID) async -> Bool {
        guard pullRequests.gh != nil else { return false }
        let now = Date.now
        let due = tasks(in: scope).filter { task in
            guard task.record.pullRequests.contains(where: \.isOpen) else { return false }
            return returnDigests.askedGitHub[task.id].map { now.timeIntervalSince($0) >= Self.returnDigestGitHubInterval } ?? true
        }
        guard !due.isEmpty else { return false }
        for task in due {
            returnDigests.askedGitHub[task.id] = now
            await refreshTaskPullRequest(task)
        }
        return true
    }

    /// A click on a fragment: the thread or task it names, or the pull request of a task already archived.
    func open(_ target: ReturnDigest.Target) {
        returnDigests.dismiss()
        switch target {
        case .thread(let id) where session(id) != nil:
            selection = .thread(id)
        case .task(let id) where task(id).map({ !$0.isArchived }) ?? false:
            selection = .task(id)
        case .url(let url):
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }
}
