import AppKit
import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// State of the PRs inspector: the open pull requests of one base checkout, listed through `gh`
/// (spec §6: `gh` keeps its own auth). Refreshed when the panel shows, every 3 minutes while it is
/// visible, and on demand. `gh` runs off the main actor.
@MainActor
@Observable
final class PullRequestsModel {
    enum Status: Equatable {
        case idle
        case loaded
        /// `gh` is not on PATH nor in Homebrew's folders.
        case ghMissing
        /// `gh auth status` failed; the payload is its output.
        case notAuthenticated(String)
        /// `gh pr list` failed for another reason (no GitHub remote, network…).
        case failed(String)
    }

    /// Repo id picked in the panel header, per scope (`nil` = follow the sidebar selection).
    var pickedRepo: [ScopeID: String] = [:]
    private(set) var repoURL: URL?
    private(set) var pullRequests: [PullRequest] = []
    private(set) var status: Status = .idle
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Task creation in flight for this PR number (the row shows a spinner).
    private(set) var openingNumber: Int?
    /// The bound pull requests of each task as `gh` last saw them, by URL (numbers repeat across repositories):
    /// their checks, mergeability and state. Fetched per task, whatever repository the panel lists.
    private(set) var taskPullRequests: [TaskID: [URL: PullRequest]] = [:]
    /// Why the last fetch of a task's pull requests failed.
    private(set) var taskPullRequestErrors: [TaskID: String] = [:]
    /// When `gh` last answered for each pull request of each task: how old its checks are (`PullRequestFreshness`).
    private(set) var taskPullRequestCheckedAt: [TaskID: [URL: Date]] = [:]
    /// The pull request the inspector shows the detail of, per task, when the user picked one; the primary otherwise.
    var selectedPullRequest: [TaskID: URL] = [:]
    /// Tasks whose pull request is being merged (the button shows a spinner).
    private(set) var merging: Set<TaskID> = []
    /// Where each task's branch stands against the default branch, as the last background pass measured it.
    private(set) var taskLags: [TaskID: TaskLag] = [:]
    /// Tasks Scope is measuring, rebasing or messaging about main right now: one pass at a time per task.
    private(set) var followingMain: Set<TaskID> = []

    func setTaskLag(_ lag: TaskLag?, for task: TaskID) {
        taskLags[task] = lag
    }

    func setFollowingMain(_ task: TaskID, _ on: Bool) {
        if on { followingMain.insert(task) } else { followingMain.remove(task) }
    }

    func setTaskPullRequest(_ pr: PullRequest, for task: TaskID) {
        taskPullRequests[task, default: [:]][pr.url] = pr
        taskPullRequestErrors[task] = nil
        taskPullRequestCheckedAt[task, default: [:]][pr.url] = .now
    }

    /// What `gh` last answered about `url` for `task`, if anything.
    func taskPullRequest(_ url: URL, for task: TaskID) -> PullRequest? {
        taskPullRequests[task]?[url]
    }

    func checkedAt(_ url: URL, for task: TaskID) -> Date? {
        taskPullRequestCheckedAt[task]?[url]
    }

    func setTaskPullRequestError(_ message: String, for task: TaskID) {
        taskPullRequestErrors[task] = message
    }

    func setMerging(_ task: TaskID, _ on: Bool) {
        if on { merging.insert(task) } else { merging.remove(task) }
    }
    let gh: GhClient?

    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var generation = 0

    static let refreshInterval: Duration = .seconds(180)

    init(problems: ProblemCenter) {
        self.problems = problems
        self.gh = GhClient.locate()
    }

    /// Points the panel at a repo: list reset and reloaded.
    func show(repo: RepoState) {
        guard repoURL != repo.url else { return }
        generation += 1
        repoURL = repo.url
        pullRequests = []
        lastRefresh = nil
        status = gh == nil ? .ghMissing : .idle
        Task { await refresh() }
    }

    func clear() {
        generation += 1
        repoURL = nil
        pullRequests = []
        status = gh == nil ? .ghMissing : .idle
    }

    func pullRequest(number: Int) -> PullRequest? {
        pullRequests.first { $0.number == number }
    }

    /// `gh pr list` in the repo. Failures land in `status`, never in the problem center (the panel shows them).
    func refresh() async {
        guard let url = repoURL, !isRefreshing else { return }
        guard let gh else {
            status = .ghMissing
            return
        }
        let generation = generation
        isRefreshing = true
        defer { isRefreshing = false }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[PullRequest], GhError> in
            do {
                return .success(try await gh.prList(in: url))
            } catch let error as GhError {
                if case .notAuthenticated = error { return .failure(error) }
                // Tell "not logged in" from "not a GitHub remote": `gh auth status` decides.
                do { try await gh.checkAuth() } catch let auth as GhError { return .failure(auth) } catch {}
                return .failure(error)
            } catch {
                return .failure(.failed(command: "gh pr list", message: String(describing: error)))
            }
        }.value
        guard generation == self.generation else { return }
        lastRefresh = .now
        switch outcome {
        case .success(let list):
            pullRequests = list
            status = .loaded
        case .failure(.notAuthenticated(let message)):
            status = .notAuthenticated(message)
        case .failure(.notInstalled):
            status = .ghMissing
        case .failure(let error):
            status = .failed(error.description)
        }
    }

    /// Sleeps `refreshInterval`, refreshes, repeats — run from the panel's `.task` so it stops on hide.
    func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func setOpening(_ number: Int?) { openingNumber = number }
}

extension AppModel {
    /// The repo the PRs panel lists: the header pick when it belongs to the current scope, else the repository Base
    /// would follow to — not the one pinned there, which is a choice made about Base.
    var pullRequestsRepo: RepoState? {
        guard let scope = currentScope else { return nil }
        if let picked = pullRequests.pickedRepo[scope.id], let repo = scope.repo(relativePath: picked) { return repo }
        return baseSubject(ignoringPin: true)?.repo
    }

    /// Opens the Pull Requests sheet, on a repo when one is given (the sidebar button, ⇧⌘P, the palette).
    func showPullRequests(repo: RepoState? = nil, in scope: ScopeState? = nil) {
        if let repo, let scope { pullRequests.pickedRepo[scope.id] = repo.id }
        globalSheet = .pullRequests
    }

    /// The task bound to pull request `number` of `repo` in `scope`, if any.
    func task(forPullRequest number: Int, repo: RepoState, in scope: ScopeID) -> TaskState? {
        let key = GraphModel.key(for: repo)
        return tasks.first { task in
            task.scopeID == scope && task.record.repos.contains { $0.repoRelativePath == key }
                && task.record.pullRequests.contains { $0.number == number && ($0.repo ?? key) == key }
        }
    }

    /// Live checks state of the task's primary PR when something read it, else `nil`.
    func liveChecks(for task: TaskState) -> PullRequest.Checks? {
        livePullRequest(for: task)?.checks
    }

    /// The task's primary pull request as `gh` last saw it (`livePullRequest(for:link:)`), `nil` without one or unread.
    func livePullRequest(for task: TaskState) -> PullRequest? {
        task.record.primaryPullRequest.flatMap { livePullRequest(for: task, link: $0) }
    }

    /// One bound pull request as `gh` last saw it: the task's own fetch first, else the PRs panel's list when it
    /// has that repository loaded.
    func livePullRequest(for task: TaskState, link: LinkedPullRequest) -> PullRequest? {
        if let own = pullRequests.taskPullRequest(link.url, for: task.id) { return own }
        guard let repo = repo(of: link, in: task), pullRequests.repoURL == task.baseURL(for: repo) else { return nil }
        return pullRequests.pullRequest(number: link.number).flatMap { $0.url == link.url ? $0 : nil }
    }

    /// Every bound pull request with what `gh` last said of it, in the task's order.
    func pullRequestStates(for task: TaskState) -> [(link: LinkedPullRequest, live: PullRequest?)] {
        task.record.pullRequests.map { ($0, livePullRequest(for: task, link: $0)) }
    }

    /// The task sandbox a link belongs to: the repository it names — its worktree on the pull request's head branch
    /// when the task holds one beside the primary — else the first (links written before the repository was kept
    /// were all in the first).
    func repo(of link: LinkedPullRequest, in task: TaskState) -> TaskRepo? {
        if let path = link.repo, let repo = task.record.repos.first(where: { $0.repoRelativePath == path }) {
            if let head = link.headRefName, head != repo.branch, let worktree = repo.worktree(onBranch: head) { return repo.sandbox(worktree) }
            return repo
        }
        return task.activeRepos.first ?? task.record.repos.first
    }

    /// The pull request the inspector's detail and single-target buttons act on: the one picked in the list, else
    /// the primary (`PullRequestSet.primary`). A pick that no longer names a bound pull request is forgotten.
    func selectedPullRequest(for task: TaskState) -> LinkedPullRequest? {
        if let url = pullRequests.selectedPullRequest[task.id], let link = task.record.pullRequests.first(where: { $0.url == url }) {
            return link
        }
        return task.record.primaryPullRequest
    }

    func selectPullRequest(_ link: LinkedPullRequest?, for task: TaskState) {
        pullRequests.selectedPullRequest[task.id] = link?.url
    }

    /// `TaskStatus.resolve`'s view of every bound pull request: the record's state until `gh` answered, then the live one.
    func pullRequestFacts(for task: TaskState) -> [PullRequestFacts] {
        pullRequestStates(for: task).map { link, live in
            PullRequestFacts(number: link.number, isDraft: live?.isDraft ?? false, checks: live?.checks ?? .none,
                             mergeable: live?.mergeable ?? .unknown,
                             state: live?.state ?? link.state.flatMap(PullRequest.State.init(rawValue:)) ?? .open)
        }
    }

    /// `open`, `merged`, `closed` for the task as a whole, live where read (`PullRequestSet.aggregateState`).
    func pullRequestState(for task: TaskState) -> String? {
        PullRequestSet.aggregateState(pullRequestStates(for: task).map { $0.live?.state.rawValue ?? $0.link.state })
    }

    /// "Open in Scope": creates the task for the PR (or switches to the existing one) and selects it, so the
    /// usual "Open a shell here / Other driver…" prompt follows.
    func openPullRequest(_ pr: PullRequest, repo: RepoState, in scope: ScopeState) async {
        if let existing = task(forPullRequest: pr.number, repo: repo, in: scope.id) {
            switchToTask(existing)
            return
        }
        guard pullRequests.openingNumber == nil else { return }
        pullRequests.setOpening(pr.number)
        defer { pullRequests.setOpening(nil) }
        let scopeRepos = scope.repos.map(\.id)
        let summaries = await graphSummaries(for: scope)
        let record: TaskRecord
        do {
            record = try await env.tasks.createForPullRequest(pr, in: scope.declaration, repo: GraphModel.key(for: repo),
                                                              scopeRepos: scopeRepos, repoSummaries: summaries,
                                                              contextFiles: contextFileNames)
        } catch {
            problems.error("Could not open #\(pr.number) in Scope", detail: String(describing: error), scope: scope.id)
            return
        }
        let state = TaskState(record: record, git: env.git)
        tasks.append(state)
        state.startWatching()
        state.refresh()
        startSetup(for: state, runCommands: true)
        selection = .task(record.id)
        scope.refreshFacts()
    }

    /// "Switch": selects the task (its last thread comes along, see `syncThreadFromSelection`).
    /// Selects the task; closes the Pull Requests sheet the row sits on, since the point is to look at the task.
    func switchToTask(_ task: TaskState) {
        task.isExpanded = true
        selection = .task(task.id)
        globalSheet = nil
    }

    func openOnGitHub(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
