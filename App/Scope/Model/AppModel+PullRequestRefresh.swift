import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Every open task's pull request, asked about in the background — not only the task on screen, whose inspector
/// keeps its faster loop — and the task archived once its pull request merges.
///
/// `PullRequestRefreshSchedule` decides who is due (every 5 minutes, staggered, backing off on failures); this asks
/// `gh` for them two at a time. Skipped while Low Power Mode is on: nothing here is urgent.
extension AppModel {
    /// How often the background pass looks for due tasks; the schedule decides which.
    static let pullRequestRefreshTick: Duration = .seconds(30)

    func startPullRequestRefresh() {
        pullRequestRefresher?.cancel()
        guard pullRequests.gh != nil else { return }
        pullRequestRefresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.pullRequestRefreshTick)
                guard !Task.isCancelled, let self else { return }
                await self.refreshDuePullRequests()
            }
        }
    }

    /// One pass: the schedule follows the open tasks, the due ones are refreshed, a merged one is archived.
    func refreshDuePullRequests(now: Date = .now) async {
        let candidates = tasks.filter { !$0.isArchived && mayHavePullRequest($0) }
        pullRequestSchedule.sync(candidates.map(\.id), now: now)
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let due = pullRequestSchedule.due(at: now).compactMap { task($0) }
        guard !due.isEmpty else { return }
        // Marked started before any of them runs, so the next tick cannot pick a task still in flight.
        for task in due { pullRequestSchedule.started(task.id, at: now) }
        var queue = due.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, pullRequestSchedule.concurrency) {
                guard let task = queue.next() else { break }
                group.addTask { await self.refreshInBackground(task) }
            }
            while await group.next() != nil {
                guard let task = queue.next() else { continue }
                group.addTask { await self.refreshInBackground(task) }
            }
        }
    }

    private func refreshInBackground(_ task: TaskState) async {
        guard !task.isArchived else { return }
        if await refreshTaskPullRequest(task) {
            let state = task.record.pullRequest?.state
            pullRequestSchedule.succeeded(task.id, settled: state == "merged" || state == "closed")
        } else {
            pullRequestSchedule.failed(task.id)
        }
        await archiveIfMerged(task)
    }

    /// A task bound to a pull request, or whose branch carries commits a pull request could be made of. One with
    /// nothing committed yet has nothing to open a pull request from: no `gh` call until it does. Summaries not
    /// read yet count as maybe.
    private func mayHavePullRequest(_ task: TaskState) -> Bool {
        if task.record.pullRequest != nil { return true }
        let summaries = task.activeRepos.compactMap { task.summary(for: $0) }
        return summaries.isEmpty || summaries.contains { $0.ahead > 0 }
    }

    /// Settings ▸ Tasks ▸ Archive a task when its pull request merges: through the sidebar's own archive, one quiet
    /// notice with Restore. A thread still running holds it until the next refresh; a restored task stays.
    func archiveIfMerged(_ task: TaskState) async {
        guard !task.isArchived else { return }
        let decision = MergedTaskArchive.decide(
            pullRequestState: task.record.pullRequest?.state, threads: threads(in: task.id).map(\.displayState),
            enabled: config.preferences.archiveMergedTasks, keptOpenAfterMerge: task.record.keptOpenAfterMerge)
        guard decision == .archive else { return }
        do {
            try await dismantleTask(task.id, .archive, notice: "Archived \(task.name): pull request merged")
        } catch {
            dismantleFailed(task, verb: "archive", error: error)
        }
    }

    /// When what is shown of the task's pull request was read: its own `gh pr view`, else the PRs panel's list.
    func pullRequestCheckedAt(for task: TaskState) -> Date? {
        if let own = pullRequests.taskPullRequests[task.id], own.number == task.record.pullRequest?.number {
            return pullRequests.taskPullRequestCheckedAt[task.id]
        }
        return livePullRequest(for: task) == nil ? nil : pullRequests.lastRefresh
    }

    /// Whether the task looks forgotten (`TaskDormancy`): idle past Settings ▸ Tasks ▸ Idle after, or its pull
    /// request closed without a merge.
    func dormancy(of task: TaskState, now: Date = .now) -> TaskDormancy {
        let sessions = threads(in: task.id)
        let dates = sessions.flatMap { session -> [Date?] in
            [session.activity.turns.last?.endedAt, session.activity.lastTool?.at, session.activity.turnStartedAt,
             session.record.lastLaunchedAt, session.record.createdAt]
        }
        let state = livePullRequest(for: task)?.state.rawValue ?? task.record.pullRequest?.state
        return TaskDormancy.classify(
            lastActivity: TaskDormancy.lastActivity(createdAt: task.record.createdAt, threadDates: dates), now: now,
            idleDays: config.preferences.dormantAfterDays, pullRequestState: state,
            threads: sessions.map(\.displayState))
    }
}
