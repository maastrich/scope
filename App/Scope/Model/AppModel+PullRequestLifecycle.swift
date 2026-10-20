import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// A task's pull requests past "Create": finding them, their checks, a failed check's log handed to the task's
/// thread, merging one when GitHub says it merges, and handing the conflicts to the thread when it does not.
///
/// A task holds every pull request its work opened — one per repository, two on one branch, a stack, a docs PR
/// beside the prototype's. Every `gh` call names the repository from the pull request's own URL and runs in the
/// sandbox the link belongs to, so a multi-repository task never asks the wrong checkout about it.
extension AppModel {
    private struct PullRequestTarget {
        let gh: GhClient
        let link: LinkedPullRequest
        let checkout: URL
        let repo: String?
    }

    private func pullRequestTarget(_ task: TaskState, _ link: LinkedPullRequest?) -> PullRequestTarget? {
        guard let gh = pullRequests.gh, let link else { return nil }
        let checkout = repo(of: link, in: task).map(\.sandboxURL) ?? task.record.threadCwd
        return PullRequestTarget(gh: gh, link: link, checkout: checkout, repo: PullRequest.repository(fromURL: link.url))
    }

    /// Keeps the task and its pull requests in step. Every sandbox is asked about the pull requests of its branch
    /// and of the branches it visited (`VisitedBranches`: a docs branch, the next of a stack) — the thread ran
    /// `gh pr create`, or one was opened on GitHub — and every link not covered by that gets `gh pr view`. What
    /// comes back refreshes the record (title, state, dates: once the task is archived nobody asks GitHub again)
    /// and the live state (checks, mergeability). `false` when `gh` failed on a bound pull request: the background
    /// pass backs off on it.
    @discardableResult
    func refreshTaskPullRequest(_ task: TaskState) async -> Bool {
        guard let gh = pullRequests.gh else { return true }
        var found: [LinkedPullRequest] = []
        var live: [PullRequest] = []
        var failed = false
        // Every worktree: each one's own branch is asked about explicitly — a branch added with `task branch add`
        // never shows in the primary sandbox's reflog — then the branches its reflog says it visited. A branch two
        // worktrees of one repository both name is asked about once.
        var asked = Set<String>()
        for repo in task.record.activeSandboxes {
            let seen = await visitedBranches(of: repo, in: task)
            for branch in seen where asked.insert("\(repo.repoRelativePath)\0\(branch)").inserted {
                do {
                    for pr in try await gh.prsForBranch(branch, in: repo.sandboxURL) {
                        found.append(LinkedPullRequest(pr, repo: repo.repoRelativePath))
                        live.append(pr)
                    }
                } catch {
                    // A branch nobody pushed, or no GitHub remote: nothing to bind, nothing to report.
                    continue
                }
            }
        }
        // Links the branches no longer name (a reflog cut, a link made from the Pull Requests sheet): asked one by one.
        for link in task.record.pullRequests where !found.contains(where: { $0.url == link.url }) {
            guard let target = pullRequestTarget(task, link) else { continue }
            do {
                let pr = try await target.gh.prView(number: link.number, in: target.checkout, repo: target.repo)
                found.append(link.refreshed(with: pr))
                live.append(pr)
            } catch {
                pullRequests.setTaskPullRequestError(String(describing: error), for: task.id)
                failed = true
            }
        }
        // An archived task keeps what it had: nothing new is bound to it, its sandboxes are gone.
        if task.isArchived { found = found.filter { link in task.record.pullRequests.contains { $0.url == link.url } } }
        for pr in live { pullRequests.setTaskPullRequest(pr, for: task.id) }
        let stale = found.filter { link in
            guard let known = task.record.pullRequests.first(where: { $0.url == link.url }) else { return true }
            return known.state != link.state || known.title != link.title || known.openedAt != link.openedAt
                || known.mergedAt != link.mergedAt || known.closedAt != link.closedAt || known.repo != link.repo
                || known.headRefName != link.headRefName || known.baseRefName != link.baseRefName
        }
        if !stale.isEmpty { await link(stale, to: task) }
        for pr in live { await recordChecks(of: pr, for: task) }
        return !failed
    }

    /// The sandbox's branch first, then the branches its reflog says it was on, the default branch left out.
    private func visitedBranches(of repo: TaskRepo, in task: TaskState) async -> [String] {
        let git = env.git
        let base = task.baseURL(for: repo)
        let sandbox = repo.sandboxURL
        return await Task.detached(priority: .utility) { () -> [String] in
            let client = await git.client(for: base)
            let current = (try? await client.output(["-C", sandbox.path(percentEncoded: false), "rev-parse", "--abbrev-ref", "HEAD"], timeout: .seconds(10)))
                .flatMap { $0 == "HEAD" ? nil : $0 } ?? repo.branch
            var excluding: Set<String> = ["HEAD"]
            if let main = await client.defaultBranch() { excluding.insert(main) }
            let visited = (try? await client.visitedBranches(at: sandbox, current: current, excluding: excluding)) ?? []
            return [current] + visited
        }.value
    }

    private func link(_ links: [LinkedPullRequest], to task: TaskState) async {
        do {
            let record = try await env.tasks.linkPullRequests(links, to: task.id)
            task.update(record: record)
        } catch {
            // A refresh that outlived a close (`settlePullRequest`) finds no record left: nothing to report.
            guard await env.tasks.task(task.id) != nil else { return }
            let labels = links.map(\.label).joined(separator: ", ")
            problems.warn("Could not bind \(labels) to the task", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// Sends the thread the end of a failed check's log with a sentence naming the check. A check that is not a
    /// GitHub Actions job has no log to fetch: the thread gets its link instead.
    func sendCheckFailure(_ check: PullRequestCheck, of task: TaskState, pullRequest link: LinkedPullRequest, to thread: ThreadID) async {
        guard let target = pullRequestTarget(task, link) else { return }
        var log: String?
        if let job = check.actionsJob {
            do {
                log = try await target.gh.failedLog(of: job, in: target.checkout, repo: target.repo)
            } catch {
                problems.warn("Could not fetch the log of \(check.title)", detail: String(describing: error), scope: task.scopeID)
            }
        }
        let text = PullRequestPrompts.checkFailed(check, pullRequest: target.link.number, log: log)
        reportUndelivered(deliver(text, to: thread, label: "the failure of \(check.title)"), task: task)
    }

    /// Hands a conflicting pull request back to the thread: merge the base in, resolve, test, push.
    func askToFixConflicts(of task: TaskState, pullRequest link: LinkedPullRequest, to thread: ThreadID) {
        guard let pr = livePullRequest(for: task, link: link) else { return }
        let text = PullRequestPrompts.fixConflicts(pullRequest: pr.number, base: pr.baseRefName, branch: pr.headRefName)
        reportUndelivered(deliver(text, to: thread, label: "the conflicts of #\(pr.number)"), task: task)
    }

    /// `gh pr merge` with the method the repository allows, after asking; then, once every pull request of the task
    /// is merged, offers to close the task, which deletes the branch the task itself created.
    func mergePullRequest(of task: TaskState, pullRequest link: LinkedPullRequest) async {
        guard let target = pullRequestTarget(task, link), let pr = livePullRequest(for: task, link: link) else { return }
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
        // Another pull request of the task still open: the task is not done, nothing to close yet.
        guard pullRequestState(for: task) == "merged" else { return }
        if await confirmForce(title: "#\(pr.number) is merged. Close “\(task.name)”?",
                              detail: "Its sandboxes are removed and its branch \(task.branch) is deleted.",
                              button: "Close Task") {
            await closeTask(task.id, deleteBranch: true)
        }
    }

    private func reportUndelivered(_ outcome: DeliveryOutcome, task: TaskState) {
        if case .failed(let reason) = outcome {
            problems.warn("Could not reach the thread", detail: reason, scope: task.scopeID)
        }
    }
}
