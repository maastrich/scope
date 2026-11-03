import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Every open task's pull request, asked about in the background — not only the task on screen, whose inspector
/// keeps its faster loop — and the task archived once its pull request merges.
///
/// `PullRequestRefreshSchedule` decides who is due (every 5 minutes while someone looks at Scope, up to an hour when
/// nobody does, staggered, backing off on failures); `PullRequestRefreshGate` decides whether anything goes out at all
/// (asleep, offline, an outage). This asks `gh` for the due ones two at a time. Skipped while Low Power Mode is on:
/// nothing here is urgent.
extension AppModel {
    /// How often the background pass looks for due tasks; the schedule decides which.
    static let pullRequestRefreshTick: Duration = .seconds(30)

    /// What one refresh of a task's pull requests came to.
    enum PullRequestRefreshOutcome: Equatable {
        case answered
        /// `gh` failed; a global cause (`GhFailure.isGlobal`) ended the refresh at its first call.
        case failed(GhFailure)
        /// Not run: the gate is closed (asleep, offline, backing off), or no `gh`.
        case skipped
    }

    func startPullRequestRefresh() {
        pullRequestRefresher?.cancel()
        guard pullRequests.gh != nil else { return }
        attentionWatch.start()
        pullRequests.mayAutoRefresh = { [weak self] in
            guard let self else { return false }
            self.updatePullRequestPacing()
            return self.pullRequestSchedule.attention == .active && self.pullRequestGate.allows(at: .now)
        }
        pullRequestRefresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.pullRequestRefreshTick)
                guard !Task.isCancelled, let self else { return }
                await self.refreshDuePullRequests()
            }
        }
    }

    /// Brings the schedule and the gate up to date with the system: who is looking, the network, sleep, and which
    /// tasks have a thread at work.
    func updatePullRequestPacing(now: Date = .now) {
        pullRequestGate.setOnline(acting.network.state.online, at: now)
        pullRequestGate.setAsleep(attentionWatch.asleep, at: now)
        pullRequestSchedule.attention = attentionWatch.attention
        for task in tasks where pullRequestSchedule.entries[task.id] != nil {
            pullRequestSchedule.setBusy(task.id, threads(in: task.id).contains(where: \.isWorking))
        }
    }

    /// One pass: the schedule follows the open tasks, the due ones are refreshed, a merged one is archived.
    func refreshDuePullRequests(now: Date = .now) async {
        let candidates = tasks.filter { !$0.isArchived && mayHavePullRequest($0) }
        pullRequestSchedule.sync(candidates.map(\.id), now: now)
        // Already known merged, held by a running thread: no `gh` call needed to archive it once the thread stops,
        // rather than at the next refresh of a settled pull request, half an hour later. Offline and asleep included.
        for task in candidates where task.record.pullRequestState == "merged" { await archiveIfMerged(task) }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        updatePullRequestPacing(now: now)
        guard pullRequestGate.allows(at: now) else { return }
        let due = pullRequestSchedule.due(at: now).compactMap { task($0) }
        guard !due.isEmpty else { return }
        // Handed out one by one, and only while the gate stays open: once a call says GitHub is out of reach, the
        // tasks still queued wait for the gate rather than fail the same way. The pass is awaited before the next
        // tick, so a queued task cannot be picked twice.
        var queue = due.makeIterator()
        func next() -> TaskState? {
            guard pullRequestGate.allows(at: .now), let task = queue.next() else { return nil }
            return task
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, pullRequestSchedule.concurrency) {
                guard let task = next() else { break }
                group.addTask { await self.refreshInBackground(task) }
            }
            while await group.next() != nil {
                guard let task = next() else { continue }
                group.addTask { await self.refreshInBackground(task) }
            }
        }
    }

    private func refreshInBackground(_ task: TaskState) async {
        guard !task.isArchived else { return }
        await refreshTaskPullRequest(task)
        await archiveIfMerged(task)
        // Failed checks and reviews wake the task's thread (`AppModel+ActingPullRequests`).
        await actOnPullRequests(of: task)
        // Independently of GitHub: fetch, measure the branch against main, and act on it (`AppModel+FollowMain`).
        guard !task.isArchived else { return }
        await followMain(task)
    }

    /// The inspector's loop for the task on screen: once a minute while Scope is in front and the gate is open,
    /// backing off with the task's failures. Nothing to ask for a task with nothing committed yet.
    func refreshForegroundPullRequest(_ task: TaskState, now: Date = .now) async {
        guard !task.isArchived, mayHavePullRequest(task) else { return }
        updatePullRequestPacing(now: now)
        pullRequestSchedule.include(task.id, now: now)
        guard pullRequestSchedule.foregroundDue(task.id, at: now) else { return }
        await refreshTaskPullRequest(task, gated: true)
    }

    /// A task bound to a pull request, or whose branch carries commits a pull request could be made of. One with
    /// nothing committed yet has nothing to open a pull request from: no `gh` call until it does. Summaries not
    /// read yet count as maybe.
    func mayHavePullRequest(_ task: TaskState) -> Bool {
        if !task.record.pullRequests.isEmpty { return true }
        let summaries = task.activeRepos.compactMap { task.summary(for: $0) }
        return summaries.isEmpty || summaries.contains { $0.ahead > 0 }
    }

    /// Settings ▸ Tasks ▸ Archive a task when its pull request merges: through the sidebar's own archive, one quiet
    /// notice with Restore and the undo toast (no ⌘Z: the user did not ask for it). Only once every pull request of the task is merged or closed, and one merged: a task
    /// with two pull requests waits for the second. Then only once nothing holds it (`MergedTaskArchive`): a thread
    /// at work or waiting, a task launched from it still open, changes not committed or not pushed, a turn started
    /// since the merge. A restored task stays.
    func archiveIfMerged(_ task: TaskState) async {
        guard !task.isArchived,
              config.preferences.archiveMergedTasks, !task.record.keptOpenAfterMerge,
              PullRequestSet.aggregateState(task.record.pullRequests.map(\.state)) == "merged" else { return }
        // Everything but git first: a task held by its threads or its children costs no `rev-list` every tick.
        guard MergedTaskArchive.decide(await mergedArchiveFacts(of: task, countingCommits: false)) == .archive else { return }
        guard MergedTaskArchive.decide(await mergedArchiveFacts(of: task)) == .archive else { return }
        // The git reads suspended: whatever moved meanwhile (an archive, a restore, a turn that started) wins.
        guard !task.isArchived, !task.isDismantling,
              MergedTaskArchive.decide(await mergedArchiveFacts(of: task, countingCommits: false)) == .archive else { return }
        let merged = task.record.pullRequests.filter(\.isMerged)
        let what = merged.count == 1 ? "pull request merged" : "\(merged.count) pull requests merged"
        do {
            try await dismantleTask(task.id, .archive, notice: "Archived \(task.name): \(what)", by: .automatic(what))
        } catch {
            dismantleFailed(task, verb: "archive", error: error)
        }
    }

    /// What `MergedTaskArchive` weighs, read from the threads, the task tree and each sandbox. Without
    /// `countingCommits`, every sandbox is taken as pushed.
    func mergedArchiveFacts(of task: TaskState, countingCommits: Bool = true, now: Date = .now) async -> MergedTaskArchive.Facts {
        let threads = threads(in: task.id).map { session -> MergedTaskArchive.Thread in
            let activity = session.activity
            let launching = if case .launching = session.phase { true } else { false }
            let starts = activity.turns.compactMap(\.startedAt) + [activity.turnStartedAt].compactMap { $0 }
            return MergedTaskArchive.Thread(
                state: session.displayState, runningAgents: session.runningSubagents(now: now), launching: launching,
                interrupted: activity.turns.last?.outcome == .exited || (activity.inTurn && !session.phase.isAlive),
                lastTurnStartedAt: starts.max())
        }
        let children = MergedTaskArchive.openDescendants(
            of: task.id, in: tasks.map { (id: $0.id, parent: $0.record.parentTask, isArchived: $0.isArchived) })
        var sandboxes: [MergedTaskArchive.Sandbox] = []
        for repo in task.record.activeSandboxes {
            let summary = task.summary(for: repo)
            if summary?.sandbox == .missing {
                sandboxes.append(.init(dirty: false, unpushed: 0))
                continue
            }
            let unpushed = countingCommits ? await unpushedCommits(in: repo, of: task) : 0
            sandboxes.append(.init(dirty: summary.map(\.isDirty), unpushed: unpushed))
        }
        return MergedTaskArchive.Facts(
            pullRequests: task.record.pullRequests.map { .init(state: $0.state, mergedAt: $0.mergedAt) },
            threads: threads, openChildren: children.count, sandboxes: sandboxes,
            enabled: config.preferences.archiveMergedTasks, keptOpenAfterMerge: task.record.keptOpenAfterMerge)
    }

    /// `GitClient.unpushedCommits`, past the heads of the task's pull requests in this repository — whichever
    /// branch they were on: a fork's, or one the sandbox visited before.
    private func unpushedCommits(in repo: TaskRepo, of task: TaskState) async -> Int? {
        let first = task.record.repos.first?.repoRelativePath ?? "."
        let heads = task.record.pullRequests.filter { link in
            TaskRepo.normalize(link.repo ?? first) == TaskRepo.normalize(repo.repoRelativePath)
        }.compactMap(\.headRefOid)
        return await env.git.client(for: task.baseURL(for: repo)).unpushedCommits(at: repo.sandboxURL, pullRequestHeads: heads)
    }

    /// When what is shown of one pull request was read: its own `gh` answer, else the PRs panel's list.
    func pullRequestCheckedAt(for task: TaskState, link: LinkedPullRequest) -> Date? {
        if let own = pullRequests.checkedAt(link.url, for: task.id) { return own }
        return livePullRequest(for: task, link: link) == nil ? nil : pullRequests.lastRefresh
    }

    /// The oldest reading among the task's pull requests: what the sidebar's one age stands for. `nil` while none was read.
    func pullRequestCheckedAt(for task: TaskState) -> Date? {
        let dates = task.record.pullRequests.compactMap { pullRequestCheckedAt(for: task, link: $0) }
        return dates.isEmpty ? nil : dates.min()
    }

    /// Whether the task looks forgotten (`TaskDormancy`): idle past Settings ▸ Tasks ▸ Idle after, or its pull
    /// request closed without a merge.
    func dormancy(of task: TaskState, now: Date = .now) -> TaskDormancy {
        let sessions = threads(in: task.id)
        let dates = sessions.flatMap { session -> [Date?] in
            // Not `lastLaunchedAt`: every launch of the app relaunches the live threads, and would reset the clock.
            [session.activity.turns.last?.endedAt, session.activity.lastTool?.at, session.activity.turnStartedAt,
             session.record.createdAt]
        }
        let state = pullRequestState(for: task)
        return TaskDormancy.classify(
            lastActivity: TaskDormancy.lastActivity(createdAt: task.record.createdAt, threadDates: dates), now: now,
            idleDays: config.preferences.dormantAfterDays, pullRequestState: state,
            threads: sessions.map(\.displayState))
    }
}
