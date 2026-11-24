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

    /// What one task asks GitHub about, read from its sandboxes with git alone.
    private struct PullRequestPlan: Sendable {
        struct Sandbox: Sendable {
            let repo: TaskRepo
            /// The repository on github.com its branches are asked about in the pass's one query; `nil` when only
            /// `gh` knows where the checkout points (GitHub Enterprise, an ssh alias, no remote, the folder gone).
            let repository: GitHubRepository?
            /// The sandbox's branch first, then the branches its reflog says it was on, the default branch left out.
            let branches: [String]
        }
        var sandboxes: [Sandbox] = []
        /// Where the remotes have those branches (`GitClient.remoteHeads`), sandbox by sandbox: a push changes it.
        var heads = ""

        var lookups: [PullRequestBatch.Lookup] {
            sandboxes.flatMap { sandbox in
                sandbox.repository.map { repository in sandbox.branches.map { PullRequestBatch.Lookup(repository: repository, branch: $0) } } ?? []
            }
        }
    }

    /// Keeps the task and its pull requests in step: a pass of one (`refreshPullRequests`).
    ///
    /// `unlessUnchanged` is for the refreshes nobody asked for (the background pass, the inspector's loop): a task
    /// whose pull requests are all merged or closed is then left alone until one of its branches is pushed.
    @discardableResult
    func refreshTaskPullRequest(_ task: TaskState, gated: Bool = false, unlessUnchanged: Bool = false) async -> PullRequestRefreshOutcome {
        await refreshPullRequests(of: [task], gated: gated, unlessUnchanged: unlessUnchanged)[task.id] ?? .skipped
    }

    /// One pass over `tasks`. Every sandbox is asked about the pull requests of its branch and of the branches it
    /// visited (`VisitedBranches`: a docs branch, the next of a stack) — the thread ran `gh pr create`, or one was
    /// opened on GitHub — all of them in one `gh api graphql` (`PullRequestBatch`), whatever the number of tasks;
    /// every link not covered by that gets `gh pr view`. What comes back refreshes the records (title, state, dates:
    /// once a task is archived nobody asks GitHub again) and the live state (checks, mergeability).
    ///
    /// A failure that is not about one task (`GhFailure.isGlobal`: offline, auth, a rate limit) ends the pass: every
    /// other call would fail the same way. When it is the query itself, the tasks stay due for the pass the gate
    /// lets out next. A link of a repository whose branch lookup already failed is not asked about either. The
    /// schedule and the gate learn the outcome, whoever asked; a `gated` pass (the automatic ones) does not run at
    /// all while the gate is closed. A pass whose caller is cancelled stops there, `skipped`: no failure for the
    /// schedule, none for the gate, no error on the task.
    @discardableResult
    func refreshPullRequests(of tasks: [TaskState], gated: Bool = false,
                             unlessUnchanged: Bool = false) async -> [TaskID: PullRequestRefreshOutcome] {
        guard let gh = pullRequests.gh, !tasks.isEmpty else { return [:] }
        if gated {
            updatePullRequestPacing()
            guard pullRequestGate.allows(at: .now) else { return [:] }
        }
        for task in tasks { pullRequestSchedule.started(task.id, at: .now) }
        var plans: [TaskID: PullRequestPlan] = [:]
        await withTaskGroup(of: (TaskID, PullRequestPlan).self) { group in
            for task in tasks { group.addTask { (task.id, await self.pullRequestPlan(of: task)) } }
            for await (id, plan) in group { plans[id] = plan }
        }
        var outcomes: [TaskID: PullRequestRefreshOutcome] = [:]
        // Merged or closed, and nothing pushed since: GitHub has nothing new to say.
        let asked = tasks.filter { task in
            !(unlessUnchanged && pullRequestSchedule.isUnchanged(task.id, heads: plans[task.id]?.heads))
        }
        let lookups = asked.flatMap { plans[$0.id]?.lookups ?? [] }
        var answer = PullRequestBatch.Answer()
        var batchFailure: GhFailure?
        if !lookups.isEmpty {
            do {
                answer = try await gh.prsForBranches(lookups)
            } catch {
                batchFailure = GhFailure.classify(error: error)
            }
        }
        // The caller went away (the inspector moved to another task): nothing failed, nothing to count.
        if batchFailure == .cancelled {
            for task in asked { pullRequestSchedule.held(task.id) }
            return outcomes
        }
        if let batchFailure, batchFailure.isGlobal {
            for task in asked {
                pullRequestSchedule.held(task.id)
                outcomes[task.id] = .failed(batchFailure)
            }
            pullRequestGate.failed(batchFailure, at: .now)
            return outcomes
        }
        var global: GhFailure?
        for task in asked {
            guard global == nil else {
                // The pass ended on an earlier task: this one is asked about when the gate opens again.
                pullRequestSchedule.held(task.id)
                continue
            }
            let outcome = await bindPullRequests(answer, batchFailure: batchFailure, plan: plans[task.id] ?? PullRequestPlan(), to: task, gh: gh)
            outcomes[task.id] = outcome
            if case .failed(let cause) = outcome, cause.isGlobal { global = cause }
        }
        // Once per pass: a streak counts passes, not the tasks one outage caught together.
        if let global {
            pullRequestGate.failed(global, at: .now)
        } else if outcomes.values.contains(.answered) {
            pullRequestGate.succeeded()
        }
        return outcomes
    }

    /// One task's share of a pass: what the query found for its branches, `gh pr view` for the links no branch
    /// names, and the record, the live state and the schedule brought up to date.
    private func bindPullRequests(_ answer: PullRequestBatch.Answer, batchFailure: GhFailure?, plan: PullRequestPlan,
                                  to task: TaskState, gh: GhClient) async -> PullRequestRefreshOutcome {
        var found: [LinkedPullRequest] = []
        var live: [PullRequest] = []
        var failure: GhFailure?
        /// Repositories whose lookup failed: their links would only fail again.
        var unreachable = Set<String>()
        // Every worktree: each one's own branch is asked about explicitly — a branch added with `task branch add`
        // never shows in the primary sandbox's reflog — then the branches its reflog says it visited. A branch two
        // worktrees of one repository both name is asked about once.
        var asked = Set<String>()
        sandboxes: for sandbox in plan.sandboxes {
            let repo = sandbox.repo
            for branch in sandbox.branches where asked.insert("\(repo.repoRelativePath)\0\(branch)").inserted {
                let outcome: PullRequestBatch.Outcome
                if let repository = sandbox.repository {
                    outcome = answer[PullRequestBatch.Lookup(repository: repository, branch: branch)] ?? .failed(batchFailure ?? .other)
                } else {
                    // Not a checkout the query can name: `gh` resolves it its own way, branch by branch.
                    do {
                        outcome = .found(try await gh.prsForBranch(branch, in: repo.sandboxURL))
                    } catch {
                        outcome = .failed(GhFailure.classify(error: error))
                    }
                }
                switch outcome {
                case .found(let prs):
                    for pr in prs {
                        found.append(LinkedPullRequest(pr, repo: repo.repoRelativePath))
                        live.append(pr)
                    }
                case .failed(let cause):
                    // The caller went away (the inspector moved to another task): nothing failed, nothing to count.
                    if cause == .cancelled { return cancelled(task) }
                    failure = failure ?? cause
                    unreachable.insert(TaskRepo.normalize(repo.repoRelativePath))
                    if cause.isGlobal { break sandboxes }
                    // This sandbox's other branches fail the same way (no GitHub remote, the folder gone).
                    continue sandboxes
                }
            }
        }
        // Links the branches no longer name (a reflog cut, a link made from the Pull Requests sheet): asked one by one.
        let first = task.record.repos.first?.repoRelativePath ?? "."
        for link in task.record.pullRequests where !found.contains(where: { $0.url == link.url }) {
            guard failure?.isGlobal != true else { break }
            guard !unreachable.contains(TaskRepo.normalize(link.repo ?? first)), let target = pullRequestTarget(task, link) else { continue }
            do {
                let pr = try await target.gh.prView(number: link.number, in: target.checkout, repo: target.repo)
                found.append(link.refreshed(with: pr))
                live.append(pr)
            } catch {
                let cause = GhFailure.classify(error: error)
                if cause == .cancelled { return cancelled(task) }
                pullRequests.setTaskPullRequestError(String(describing: error), for: task.id)
                failure = failure ?? cause
            }
        }
        // An archived task keeps what it had: nothing new is bound to it, its sandboxes are gone.
        if task.isArchived { found = found.filter { link in task.record.pullRequests.contains { $0.url == link.url } } }
        // A pull request the user forgot stays forgotten: not bound again, not shown, not counted.
        found = task.record.discovered(found)
        live = live.filter { !task.record.ignores($0.url) }
        live = await pullRequests.explainingCancellations(live)
        for pr in live { pullRequests.setTaskPullRequest(pr, for: task.id) }
        let stale = found.filter { link in
            guard let known = task.record.pullRequests.first(where: { $0.url == link.url }) else { return true }
            return known.state != link.state || known.title != link.title || known.openedAt != link.openedAt
                || known.mergedAt != link.mergedAt || known.closedAt != link.closedAt || known.repo != link.repo
                || known.headRefName != link.headRefName || known.baseRefName != link.baseRefName
                || (link.headRefOid != nil && known.headRefOid != link.headRefOid)
        }
        // A notice the gate held while the orchestrator worked is offered again at the next refresh.
        if !stale.isEmpty { await link(stale, to: task) } else { noticeTopicMilestones(of: task) }
        for pr in live { await recordChecks(of: pr, for: task) }
        if let failure {
            pullRequestSchedule.failed(task.id)
            return .failed(failure)
        }
        pullRequestSchedule.succeeded(task.id, settled: PullRequestSet.isSettled(task.record.pullRequests.map(\.state)), heads: plan.heads)
        return .answered
    }

    /// A refresh whose caller was cancelled: `skipped`, the task still due, no failure for the schedule or the gate.
    private func cancelled(_ task: TaskState) -> PullRequestRefreshOutcome {
        pullRequestSchedule.held(task.id)
        return .skipped
    }

    /// What a pass asks for `task`: per sandbox, the repository on GitHub, its branch and the branches it visited,
    /// and where the remotes have them. Git only, off the main actor.
    private func pullRequestPlan(of task: TaskState) async -> PullRequestPlan {
        let git = env.git
        let sandboxes = task.record.activeSandboxes.map { (repo: $0, base: task.baseURL(for: $0)) }
        return await Task.detached(priority: .utility) { () -> PullRequestPlan in
            var plan = PullRequestPlan()
            var heads: [String] = []
            for (repo, base) in sandboxes {
                let client = await git.client(for: base)
                let sandbox = repo.sandboxURL
                let current = (try? await client.output(["-C", sandbox.path(percentEncoded: false), "rev-parse", "--abbrev-ref", "HEAD"], timeout: .seconds(10)))
                    .flatMap { $0 == "HEAD" ? nil : $0 } ?? repo.branch
                var excluding: Set<String> = ["HEAD"]
                if let main = await client.defaultBranch() { excluding.insert(main) }
                let visited = (try? await client.visitedBranches(at: sandbox, current: current, excluding: excluding)) ?? []
                let branches = [current] + visited
                plan.sandboxes.append(.init(repo: repo, repository: await client.gitHubRepository(at: sandbox), branches: branches))
                heads.append("\(repo.sandboxKey) \(branches.joined(separator: " "))\n\(await client.remoteHeads(at: sandbox, branches: branches))")
            }
            plan.heads = heads.joined(separator: "\n\n")
            return plan
        }.value
    }

    private func link(_ links: [LinkedPullRequest], to task: TaskState) async {
        do {
            let record = try await env.tasks.linkPullRequests(links, to: task.id)
            task.update(record: record)
            attributeTopicsAfterPullRequests(of: task)
            noticeTopicMilestones(of: task)
        } catch {
            // A refresh that outlived a close (`settlePullRequest`) finds no record left: nothing to report.
            guard await env.tasks.task(task.id) != nil else { return }
            let labels = links.map(\.label).joined(separator: ", ")
            problems.warn("Could not bind \(labels) to the task", error: error, scope: task.scopeID)
        }
    }

    /// `gh pr close` for a sweep that was asked to (*Also close the pull requests on GitHub*): one line for the notice.
    func closeOnGitHub(_ link: LinkedPullRequest, of task: TaskState) async -> String {
        guard let target = pullRequestTarget(task, link) else { return "\(link.label): gh is not available, left open on GitHub" }
        do {
            try await target.gh.prClose(number: link.number, in: target.checkout, repo: target.repo)
            return "\(link.label): closed on GitHub"
        } catch {
            return "\(link.label): could not close it on GitHub — \(String(describing: error))"
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
                problems.warn("Could not fetch the log of \(check.title)", error: error, scope: task.scopeID)
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

    /// Hands a green pull request to the thread: merge it when done (`PullRequestPrompts.readyToMerge`).
    func askToMerge(of task: TaskState, pullRequest link: LinkedPullRequest, to thread: ThreadID) {
        guard let pr = livePullRequest(for: task, link: link) else { return }
        let text = PullRequestPrompts.readyToMerge(pullRequest: pr.number, base: pr.baseRefName,
                                                   reviewNeeded: pr.reviewDecision == .reviewRequired)
        reportUndelivered(deliver(text, to: thread, label: "the merge of #\(pr.number)"), task: task)
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
            problems.error("Could not read how #\(pr.number) may be merged", error: error, scope: task.scopeID)
            return
        }
        guard await confirmForce(title: "Merge #\(pr.number) into \(pr.baseRefName)?",
                                 detail: "“\(pr.title)” — gh pr merge --\(method.rawValue). The branch is kept until you close the task.",
                                 button: "Merge", destructive: false) else { return }
        do {
            try await target.gh.prMerge(number: pr.number, method: method, in: target.checkout, repo: target.repo)
        } catch {
            problems.error("Could not merge #\(pr.number)", error: error, scope: task.scopeID)
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
