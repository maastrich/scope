import Foundation
import ScopeCore
import ScopeGit

/// Where a scope's repo discovery is.
enum DiscoveryPhase: Equatable, Sendable {
    case idle
    case scanning
    case failed(String)
}

/// One declared scope: its declaration, the repos found inside, what kind of folder it turned out to
/// be, and the file-system watcher that keeps all of that current.
@MainActor
@Observable
final class ScopeState: Identifiable {
    let id: ScopeID
    var declaration: ScopeDeclaration
    /// Primary repos only, sorted by relative path. `RepoState` identity is stable across rescans.
    private(set) var repos: [RepoState] = []
    private(set) var kind: ScopeKind
    private(set) var discovery: DiscoveryPhase = .idle
    /// Whether the sidebar lists the repositories of this scope (collapsed by default; persisted in the UI state).
    var reposShown = false
    /// Whether the sidebar expands the "Loose threads" group — the threads of this scope that belong to no task
    /// (expanded by default; persisted in the UI state).
    var looseThreadsShown = true

    @ObservationIgnored private let git: GitClientRegistry
    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var watcher: ScopeWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanQueued = false
    @ObservationIgnored private var existenceCheck: Task<Void, Never>?
    @ObservationIgnored private var reportedMissing = false

    /// How often a missing root is checked for its return.
    static let existenceInterval: Duration = .seconds(30)

    init(declaration: ScopeDeclaration, git: GitClientRegistry, problems: ProblemCenter) {
        self.id = declaration.id
        self.declaration = declaration
        self.git = git
        self.problems = problems
        self.kind = Self.rootExists(declaration.url) ? .plain : .missing
    }

    var url: URL { declaration.url }

    var name: String {
        get { declaration.name }
        set { declaration.name = newValue }
    }

    /// Relative paths of the repos currently shown (what the watcher's classifier needs).
    var knownRepoPaths: Set<String> { Set(repos.map(\.id)) }

    func repo(relativePath: String) -> RepoState? {
        repos.first { $0.id == relativePath }
    }

    // MARK: Watching

    /// Starts the FSEvents watcher. No watcher for a missing root; a 30 s check re-arms it when it returns.
    func startWatching() {
        guard watcher == nil else { return }
        guard Self.rootExists(url) else {
            markMissing()
            return
        }
        let watcher = ScopeWatcher(
            root: url,
            depth: declaration.discoveryDepth,
            knownRepos: { [weak self] in
                await MainActor.run { self?.knownRepoPaths ?? [] }
            },
            onChange: { [weak self] hint in
                self?.apply(hint)
            }
        )
        self.watcher = watcher
        watcher.start()
        existenceCheck?.cancel()
        existenceCheck = nil
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        existenceCheck?.cancel()
        existenceCheck = nil
    }

    /// The depth changed: the watcher classifies by depth, so it is rebuilt.
    func restartWatching() {
        stopWatching()
        startWatching()
    }

    /// Manual refresh: deliver pending watcher hints, rescan fully, refresh every repo.
    func refresh() {
        let watcher = watcher
        Task { [weak self] in
            await watcher?.flush()
            guard let self else { return }
            await self.rescan(full: true)
            self.refreshFacts()
        }
    }

    // MARK: Discovery

    /// Scans off the main actor, then diffs: unchanged `RepoState`s are kept, new ones inserted, gone ones removed.
    /// A scan requested while one runs is queued once.
    func rescan(full: Bool = false) async {
        if scanTask != nil {
            rescanQueued = true
            return
        }
        guard Self.rootExists(url) else {
            markMissing()
            return
        }
        if kind == .missing {
            // The folder is back.
            kind = .plain
            reportedMissing = false
            startWatching()
        }
        discovery = .scanning
        let root = url
        let depth = declaration.discoveryDepth
        let task = Task<Void, Never> { [weak self] in
            let found = await Task.detached(priority: .utility) {
                RepoDiscovery(maxDepth: depth).scan(root)
            }.value
            guard let self else { return }
            self.applyScan(found)
        }
        scanTask = task
        await task.value
        scanTask = nil
        if rescanQueued {
            rescanQueued = false
            await rescan(full: full)
        }
    }

    private func applyScan(_ found: [DiscoveredRepo]) {
        let rootExists = Self.rootExists(url)
        kind = ScopeKind.classify(rootExists: rootExists, repos: found)
        guard rootExists else {
            discovery = .idle
            markMissing()
            return
        }
        let primary = found.filter { !$0.isSecondary }
        let existing = Dictionary(repos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [RepoState] = []
        var fresh: [RepoState] = []
        for repo in primary {
            if let state = existing[repo.relativePath] {
                state.update(discovered: repo)
                next.append(state)
            } else {
                let state = RepoState(discovered: repo, git: git)
                next.append(state)
                fresh.append(state)
            }
        }
        for state in repos where !primary.contains(where: { $0.relativePath == state.id }) {
            Task { await git.forget(state.url) }
        }
        repos = next.sorted { $0.id < $1.id }
        discovery = .idle
        for state in fresh { state.refreshFacts() }
    }

    /// Refreshes the facts of the given repos (`nil` = all).
    func refreshFacts(relativePaths: Set<String>? = nil) {
        for repo in repos where relativePaths?.contains(repo.id) ?? true {
            repo.refreshFacts()
        }
    }

    /// Watcher callback.
    func apply(_ hint: ScopeChangeHint) {
        if hint.rootChanged, !Self.rootExists(url) {
            markMissing()
            return
        }
        if hint.needsRescan {
            Task { await rescan(full: hint.fullRescan || hint.rootChanged) }
        }
        if !hint.touchedRepos.isEmpty {
            refreshFacts(relativePaths: hint.touchedRepos)
        }
    }

    // MARK: Missing root

    private func markMissing() {
        kind = .missing
        discovery = .idle
        watcher?.stop()
        watcher = nil
        if !reportedMissing {
            reportedMissing = true
            problems.warn(
                "\(declaration.name) is missing",
                detail: "\(declaration.path) does not exist (unmounted volume, deleted or moved). Threads open again once it is back.",
                scope: id,
                actions: [ProblemAction(title: "Locate…", kind: .locateScope(id))]
            )
        }
        guard existenceCheck == nil else { return }
        existenceCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ScopeState.existenceInterval)
                guard let self, !Task.isCancelled else { return }
                if Self.rootExists(self.url) {
                    self.existenceCheck = nil
                    await self.rescan(full: true)
                    return
                }
            }
        }
    }

    nonisolated static func rootExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
