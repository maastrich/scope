import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// What the sidebar shows for one repo of a task: `+N −M` against the merge-base, the number of
/// uncommitted files, and whether the sandbox folder is still there.
struct RepoDeltaSummary: Equatable, Sendable {
    enum SandboxState: Equatable, Sendable { case clean, dirty(Int), missing }

    var additions = 0
    var deletions = 0
    var sandbox: SandboxState = .clean

    var isDirty: Bool { if case .dirty = sandbox { return true } else { return false } }
}

/// One task of a scope: its record, a cached per-repo delta summary kept fresh by an FSEvents
/// watcher on the task root (throttled to one refresh per second), and the sidebar expansion.
@MainActor
@Observable
final class TaskState: Identifiable {
    let id: TaskID
    private(set) var record: TaskRecord
    /// Keyed by `TaskRepo.repoRelativePath`.
    private(set) var summaries: [String: RepoDeltaSummary] = [:]
    private(set) var isRefreshing = false
    /// Bumped after every completed refresh; the Delta inspector reloads when it changes.
    private(set) var changeTick = 0
    var isExpanded = true

    @ObservationIgnored private let git: GitClientRegistry
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var throttle: Throttle?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var queued = false

    init(record: TaskRecord, git: GitClientRegistry) {
        self.id = record.id
        self.record = record
        self.git = git
    }

    var name: String { record.name }
    var branch: String { record.branch }
    var scopeID: ScopeID { record.scopeID }
    var isArchived: Bool { record.isArchived }
    var activeRepos: [TaskRepo] { record.activeRepos }
    var scopeRootURL: URL { URL(fileURLWithPath: record.scopeRoot, isDirectory: true) }

    /// `api · web`, or the scope name for a repo scope.
    var reposCaption: String {
        let repos = activeRepos
        if repos.count == 1, repos[0].isScopeRoot { return record.scopeName }
        return repos.map(\.name).joined(separator: " · ")
    }

    /// Base checkout of a task repo (`<scopeRoot>/<repo>`; the scope root itself for `"."`).
    func baseURL(for repo: TaskRepo) -> URL {
        repo.isScopeRoot ? scopeRootURL : scopeRootURL.appending(path: repo.repoRelativePath, directoryHint: .isDirectory)
    }

    func summary(for repo: TaskRepo) -> RepoDeltaSummary? { summaries[repo.repoRelativePath] }

    var totalAdditions: Int { summaries.values.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { summaries.values.reduce(0) { $0 + $1.deletions } }
    var dirtyRepoCount: Int { summaries.values.filter(\.isDirty).count }

    func update(record: TaskRecord) {
        let sandboxesChanged = record.activeRepos.map(\.sandboxPath) != self.record.activeRepos.map(\.sandboxPath)
        self.record = record
        // A repository added to the task brings a worktree directory the running watcher does not cover.
        if sandboxesChanged, watcher != nil {
            stopWatching()
            startWatching()
        }
        refresh()
    }

    // MARK: Watching

    func startWatching() {
        guard watcher == nil, !record.isArchived, ScopeState.rootExists(record.rootURL) else { return }
        let throttle = Throttle(minimumInterval: .seconds(1)) { [weak self] in
            await MainActor.run { self?.refresh() }
        }
        self.throttle = throttle
        // The sandboxes' git state (index, HEAD, branch refs) lives in the base checkouts, outside the root.
        let gitWatch = TaskGitWatch.resolve(sandboxes: record.activeRepos.map(\.sandboxURL),
                                            branches: record.activeRepos.map(\.branch))
        let watcher = FSEventsWatcher(paths: [record.rootURL] + gitWatch.watchedDirectories, latency: 0.5)
        self.watcher = watcher
        watcher.start()
        pump = Task.detached(priority: .utility) {
            for await batch in watcher.events {
                // Everything under `.git/` except index/HEAD/refs is noise (packed objects, locks).
                let relevant = batch.paths.contains { path in
                    if let relevance = gitWatch.relevance(of: path) { return relevance }
                    guard let range = path.range(of: "/.git/") else { return true }
                    let inside = path[range.upperBound...]
                    return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/")
                }
                if relevant { await throttle.fire() }
            }
        }
    }

    func stopWatching() {
        pump?.cancel()
        pump = nil
        watcher?.stop()
        watcher = nil
        let throttle = throttle
        Task { await throttle?.cancel() }
        self.throttle = nil
    }

    // MARK: Refresh

    /// Reloads the per-repo summaries off the main actor. Coalesced: one in flight, one queued.
    func refresh() {
        if inFlight {
            queued = true
            return
        }
        inFlight = true
        let record = record
        let git = git
        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.isRefreshing = true
        }
        Task { [weak self] in
            var next: [String: RepoDeltaSummary] = [:]
            for repo in record.activeRepos {
                next[repo.repoRelativePath] = await Self.summarize(repo: repo, task: record, git: git)
            }
            spinner.cancel()
            guard let self else { return }
            self.summaries = next
            self.changeTick += 1
            self.isRefreshing = false
            self.inFlight = false
            if self.queued {
                self.queued = false
                self.refresh()
            }
        }
    }

    nonisolated private static func summarize(repo: TaskRepo, task: TaskRecord, git: GitClientRegistry) async -> RepoDeltaSummary {
        var summary = RepoDeltaSummary()
        guard ScopeState.rootExists(repo.sandboxURL) else {
            summary.sandbox = .missing
            return summary
        }
        let scopeRoot = URL(fileURLWithPath: task.scopeRoot, isDirectory: true)
        let base = repo.isScopeRoot ? scopeRoot : scopeRoot.appending(path: repo.repoRelativePath, directoryHint: .isDirectory)
        let client = await git.client(for: base)
        if let delta = try? await Delta.load(mode: .task, in: repo.sandboxURL, using: client) {
            summary.additions = delta.summary.additions
            summary.deletions = delta.summary.deletions
        }
        if let uncommitted = try? await Delta.load(mode: .uncommitted, in: repo.sandboxURL, using: client) {
            summary.sandbox = uncommitted.files.isEmpty ? .clean : .dirty(uncommitted.files.count)
        }
        return summary
    }
}
