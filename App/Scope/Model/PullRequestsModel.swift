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
    /// The bound pull request of each task as `gh pr view` last saw it: its checks, mergeability and state.
    /// Fetched per task, whatever repository the panel lists.
    private(set) var taskPullRequests: [TaskID: PullRequest] = [:]
    /// Why the last fetch of a task's pull request failed.
    private(set) var taskPullRequestErrors: [TaskID: String] = [:]
    /// Tasks whose pull request is being merged (the button shows a spinner).
    private(set) var merging: Set<TaskID> = []

    func setTaskPullRequest(_ pr: PullRequest, for task: TaskID) {
        taskPullRequests[task] = pr
        taskPullRequestErrors[task] = nil
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
    /// The repo the PRs panel lists: the header pick when it belongs to the current scope, else what Base shows.
    var pullRequestsRepo: RepoState? {
        guard let scope = currentScope else { return nil }
        if let picked = pullRequests.pickedRepo[scope.id], let repo = scope.repo(relativePath: picked) { return repo }
        return baseRepo
    }

    /// Shows the PRs panel for a repo (⌘⇧P, palette).
    func showPullRequests(repo: RepoState? = nil, in scope: ScopeState? = nil) {
        if let repo, let scope { pullRequests.pickedRepo[scope.id] = repo.id }
        inspectorTab = .pullRequests
        inspectorShown = true
    }

    /// The task bound to pull request `number` of `repo` in `scope`, if any.
    func task(forPullRequest number: Int, repo: RepoState, in scope: ScopeID) -> TaskState? {
        let key = GraphModel.key(for: repo)
        return tasks.first { task in
            task.scopeID == scope && task.record.pullRequest?.number == number
                && task.record.repos.contains { $0.repoRelativePath == key }
        }
    }

    /// Live checks state of the task's PR when the PRs panel has that repo loaded, else `nil`.
    func liveChecks(for task: TaskState) -> PullRequest.Checks? {
        livePullRequest(for: task)?.checks
    }

    /// The task's PR as `gh` last saw it: its own fetch first, else the PRs panel's list when it has that repo.
    func livePullRequest(for task: TaskState) -> PullRequest? {
        if let own = pullRequests.taskPullRequests[task.id], own.number == task.record.pullRequest?.number { return own }
        guard let pr = task.record.pullRequest, let repo = task.activeRepos.first ?? task.record.repos.first,
              pullRequests.repoURL == task.baseURL(for: repo) else { return nil }
        return pullRequests.pullRequest(number: pr.number)
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
    func switchToTask(_ task: TaskState) {
        task.isExpanded = true
        selection = .task(task.id)
    }

    func openOnGitHub(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
