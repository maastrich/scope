import Foundation
import ScopeAssist
import ScopeCore
import ScopeGit
import ScopeTasks

/// The pull request triggers (`ActingTrigger.ciFailed`, `.review`), run after every background refresh of a task.
/// Conflicts and the base moving go through `AppModel+FollowMain`, which already measures the branch against main.
extension AppModel {
    /// Per pull request: when it was last seen failing on its head, and what the last review probe found.
    struct ReviewProbe {
        var updatedAt: Date
        /// Fresh comments were seen but their batch was still coming in: the next refresh asks again.
        var settling: Bool
    }

    /// A pull request this young may get a review any minute (Copilot's comes within a few).
    static let eagerAfterOpening: TimeInterval = 30 * 60

    func actOnPullRequests(of task: TaskState, now: Date = .now) async {
        guard !task.isArchived else { return }
        let open = pullRequestStates(for: task).compactMap { state in state.live.map { (state.link, $0) } }
            .filter { $0.1.state == .open }
        var eager = false
        for (link, pr) in open {
            checkFailedChecks(of: pr, in: task, now: now)
            let settling = await checkReviews(of: pr, link: link, in: task, now: now)
            let young = pr.createdAt.map { now.timeIntervalSince($0) < Self.eagerAfterOpening } ?? false
            eager = eager || settling || (!pr.isDraft && (young || pr.reviewDecision == .reviewRequired))
        }
        pullRequestSchedule.setEager(task.id, eager)
    }

    // MARK: Checks

    private func checkFailedChecks(of pr: PullRequest, in task: TaskState, now: Date) {
        guard preference(.ciFailed).enabled, let head = pr.headRefOid else { return }
        let failing = pr.checkRuns.filter { $0.state == .failing }
        let mark = "\(pr.url.absoluteString)@\(head)"
        guard !failing.isEmpty else {
            acting.failingSince[mark] = nil
            return
        }
        let since = acting.failingSince[mark] ?? now
        acting.failingSince[mark] = since
        let pending = pr.checkRuns.count { $0.state == .pending }
        let thread = actingThread(in: task.id)
        if let thread {
            let activity = thread.activity
            let idleSince = activity.inTurn || thread.isWorking ? nil : (activity.turns.last?.endedAt ?? thread.record.createdAt)
            guard CheckWake.isDue(failing: failing.count, pending: pending, failingSince: since, threadIdleSince: idleSince, now: now)
            else { return }
        }
        let checks = failing.map { check in
            ActingPrompts.FailedCheck(title: check.title, url: check.detailsURL.map {
                ActionsJob.pullRequestLink($0, number: pr.number, pullRequestURL: pr.url)
            })
        }
        let names = failing.prefix(3).map(\.title).joined(separator: ", ")
        fire(.ciFailed, in: task, key: "ci@\(head)",
             message: ActingPrompts.checksFailed(pullRequest: pr.number, head: head, checks: checks), cause: "failing",
             notice: "#\(pr.number) failed \(names)\(failing.count > 3 ? " and \(failing.count - 3) more" : "")")
    }

    // MARK: Reviews

    /// Asks GitHub for the pull request's reviews only when it changed since the last probe, or a batch was still
    /// coming in; hands a settled batch to the task's thread. `true` while a batch is settling.
    private func checkReviews(of pr: PullRequest, link: LinkedPullRequest, in task: TaskState, now: Date) async -> Bool {
        guard preference(.review).enabled, let gh = pullRequests.gh, let repo = PullRequest.repository(fromURL: pr.url) else { return false }
        let subject = pr.url.absoluteString
        if let probe = acting.reviewProbes[subject], probe.updatedAt == pr.updatedAt, !probe.settling { return false }
        let checkout = self.repo(of: link, in: task).map(\.sandboxURL) ?? task.record.threadCwd
        let activity: PullRequestReviewActivity
        do {
            activity = try await gh.reviewActivity(number: pr.number, repo: repo, in: checkout)
        } catch {
            Log.app.notice("review probe of #\(pr.number) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // Nothing from before the trigger existed, nor from before the task: the first probe of an old pull request
        // must not wake its thread with a week of comments.
        let floor = max(acting.ledger.mark(.review, "since") ?? now, task.record.createdAt)
        if acting.ledger.mark(.review, "since") == nil {
            acting.ledger.setMark(.review, "since", to: now)
            saveActingLedger()
        }
        let handled = max(acting.ledger.mark(.review, subject) ?? floor, floor)
        let items = activity.items.map { item in
            ReviewWake.Item(id: item.id, kind: ReviewWake.Kind(rawValue: item.kind.rawValue) ?? .conversation, author: item.author,
                            body: item.body, at: item.at, url: item.url, state: item.state, path: item.path, line: item.line,
                            handled: item.handled, association: item.association)
        }
        let fresh = items.contains { $0.at > handled && ReviewWake.matters($0, viewer: activity.viewer) }
        guard let batch = ReviewWake.batch(items, viewer: activity.viewer, handledThrough: handled, now: now) else {
            acting.reviewProbes[subject] = ReviewProbe(updatedAt: pr.updatedAt, settling: fresh)
            return fresh
        }
        let verdict = fire(.review, in: task, key: batch.key,
                           message: ActingPrompts.review(pullRequest: pr.number, comments: batch.comments), cause: "comments",
                           notice: "#\(pr.number) got \(batch.comments.count) review comment\(batch.comments.count == 1 ? "" : "s")")
        // Held (the thread is at work, the user typing): asked again next time. Anything else settles the batch.
        if case .hold = verdict {
            acting.reviewProbes[subject] = ReviewProbe(updatedAt: pr.updatedAt, settling: true)
            return true
        }
        acting.ledger.setMark(.review, subject, to: batch.newest)
        saveActingLedger()
        acting.reviewProbes[subject] = ReviewProbe(updatedAt: pr.updatedAt, settling: false)
        return false
    }
}
