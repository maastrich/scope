import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// A task's pull request past "Create": its checks, a failed check's log handed to the task's thread, merging
/// when GitHub says it merges, and handing the conflicts to the thread when it does not.
///
/// Every `gh` call names the repository from the pull request's own URL, so a multi-repository task never asks
/// the wrong checkout about it.
extension AppModel {
    private struct PullRequestTarget {
        let gh: GhClient
        let number: Int
        let checkout: URL
        let repo: String?
    }

    private func pullRequestTarget(_ task: TaskState) -> PullRequestTarget? {
        guard let gh = pullRequests.gh, let link = task.record.pullRequest else { return nil }
        return PullRequestTarget(gh: gh, number: link.number, checkout: task.record.threadCwd,
                                 repo: PullRequest.repository(fromURL: link.url))
    }

    /// Keeps the task and its pull request in step. A task without one is bound to the pull request of its
    /// branch when there is one — the thread ran `gh pr create`, or the PR was opened on GitHub — since the
    /// record only ever learnt about a PR at creation or from the Delta panel's own **Create PR**. A bound task
    /// gets `gh pr view`: checks, mergeability, state, and the title the chip shows, which GitHub lets drift.
    func refreshTaskPullRequest(_ task: TaskState) async {
        if task.record.pullRequest == nil { await adoptPullRequest(of: task) }
        guard let target = pullRequestTarget(task) else { return }
        do {
            let pr = try await target.gh.prView(number: target.number, in: target.checkout, repo: target.repo)
            pullRequests.setTaskPullRequest(pr, for: task.id)
            if task.record.pullRequest?.number == pr.number, task.record.pullRequest?.title != pr.title {
                await link(pr, to: task)
            }
        } catch {
            pullRequests.setTaskPullRequestError(String(describing: error), for: task.id)
        }
    }

    /// `gh pr view` in each sandbox, the first repository whose branch has a pull request wins.
    private func adoptPullRequest(of task: TaskState) async {
        guard let gh = pullRequests.gh else { return }
        for repo in task.record.activeRepos {
            guard let url = try? await gh.prView(in: repo.sandboxURL), let number = Int(url.lastPathComponent),
                  let pr = try? await gh.prView(number: number, in: repo.sandboxURL, repo: PullRequest.repository(fromURL: url))
            else { continue }
            // Bound meanwhile (Create PR, or an earlier refresh): the first binding stands.
            guard task.record.pullRequest == nil else { return }
            await link(pr, to: task)
            return
        }
    }

    private func link(_ pr: PullRequest, to task: TaskState) async {
        do {
            let record = try await env.tasks.linkPullRequest(LinkedPullRequest(pr), to: task.id)
            task.update(record: record)
        } catch {
            problems.warn("Could not bind #\(pr.number) to the task", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// Sends the thread the end of a failed check's log with a sentence naming the check. A check that is not a
    /// GitHub Actions job has no log to fetch: the thread gets its link instead.
    func sendCheckFailure(_ check: PullRequestCheck, of task: TaskState, to thread: ThreadID) async {
        guard let target = pullRequestTarget(task) else { return }
        var log: String?
        if let job = check.actionsJob {
            do {
                log = try await target.gh.failedLog(of: job, in: target.checkout, repo: target.repo)
            } catch {
                problems.warn("Could not fetch the log of \(check.title)", detail: String(describing: error), scope: task.scopeID)
            }
        }
        let text = PullRequestPrompts.checkFailed(check, pullRequest: target.number, log: log)
        reportUndelivered(deliver(text, to: thread, label: "the failure of \(check.title)"), task: task)
    }

    /// Hands a conflicting pull request back to the thread: merge the base in, resolve, test, push.
    func askToFixConflicts(of task: TaskState, to thread: ThreadID) {
        guard let pr = livePullRequest(for: task) else { return }
        let text = PullRequestPrompts.fixConflicts(pullRequest: pr.number, base: pr.baseRefName, branch: pr.headRefName)
        reportUndelivered(deliver(text, to: thread, label: "the conflicts of #\(pr.number)"), task: task)
    }

    /// `gh pr merge` with the method the repository allows, after asking; then offers to close the task, which
    /// deletes the branch the task itself created.
    func mergePullRequest(of task: TaskState) async {
        guard let target = pullRequestTarget(task), let pr = livePullRequest(for: task) else { return }
        pullRequests.setMerging(task.id, true)
        defer { pullRequests.setMerging(task.id, false) }
        let method: MergeMethod
        do {
            guard let allowed = try await target.gh.mergeMethod(in: target.checkout, repo: target.repo) else {
                problems.warn("The repository of #\(pr.number) allows no merge method", scope: task.scopeID)
                return
            }
            method = allowed
        } catch {
            problems.error("Could not read how #\(pr.number) may be merged", detail: String(describing: error), scope: task.scopeID)
            return
        }
        guard await confirmForce(title: "Merge #\(pr.number) into \(pr.baseRefName)?",
                                 detail: "“\(pr.title)” — gh pr merge --\(method.rawValue). The branch is kept until you close the task.",
                                 button: "Merge", destructive: false) else { return }
        do {
            try await target.gh.prMerge(number: pr.number, method: method, in: target.checkout, repo: target.repo)
        } catch {
            problems.error("Could not merge #\(pr.number)", detail: String(describing: error), scope: task.scopeID)
            return
        }
        await refreshTaskPullRequest(task)
        if await confirmForce(title: "#\(pr.number) is merged. Close “\(task.name)”?",
                              detail: "Its sandboxes are removed and its branch \(task.branch) is deleted.",
                              button: "Close Task") {
            await closeTask(task.id, deleteBranch: true, confirmed: true)
        }
    }

    private func reportUndelivered(_ outcome: DeliveryOutcome, task: TaskState) {
        if case .failed(let reason) = outcome {
            problems.warn("Could not reach the thread", detail: reason, scope: task.scopeID)
        }
    }
}
