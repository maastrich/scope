import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// The three sub-sections of the Base panel.
enum BaseSection: String, CaseIterable, Hashable {
    case files = "Files"
    case search = "Search"
    case history = "History"
}

/// What the read-only viewer shows.
enum BaseFileContent: Equatable {
    case loading
    case text(String)
    /// Encoded bytes of an image file (`ImageFiles.isImage`); decoded by the viewer.
    case image(Data)
    case unavailable(String)
}

/// State of the Base inspector (spec §4.5) for one base checkout: branch, "behind N", file tree, the
/// viewer, search and recent history. Git runs off the main actor through the shared registry; the
/// "behind" fetch is throttled to one per minute per repo.
@MainActor
@Observable
final class BaseModel {
    /// Repositories pinned in the panel header, keyed by `BaseContext.key` and valued by graph key. A pin belongs to
    /// the task, loose thread or scope it was made in; no entry means the panel follows the selection.
    var pins: [String: String] = [:]
    /// The repository last shown in each scope (graph key): what a scope row falls back to. Written when the panel
    /// shows a repository, so it is not observed — reading it must not redraw the panel that just wrote it.
    @ObservationIgnored var recent: [ScopeID: String] = [:]
    var section: BaseSection = .files
    private(set) var repoURL: URL?
    private(set) var behind: Int?
    private(set) var isFetching = false
    private(set) var isPulling = false
    private(set) var tree: FileNode?
    var selectedPath: String?
    /// Line the viewer scrolls to after `open(path:line:)`.
    var targetLine: Int?
    private(set) var content: BaseFileContent?
    var query = ""
    /// Search toggles (`Aa`, `.*`, `\b`) and the optional subpath scope of the Search section.
    var searchOptions = BaseSearchOptions(caseSensitive: false, regex: false, wholeWord: false)
    var searchSubpath = ""
    private(set) var results: [SearchMatch] = []
    private(set) var isSearching = false
    /// Inline error of the last search (`nil` when it succeeded).
    private(set) var searchError: String?
    /// The pattern the current `results` answer (Return re-runs the search only when the query moved on).
    private(set) var searchedQuery: String?
    /// `rg` when installed, else `git grep` — decided once per app run.
    let searchTool = SearchTool.locate()
    private(set) var commits: [Commit] = []
    private(set) var isLoadingHistory = false

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var lastFetch: [URL: Date] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchGeneration = 0

    static let fetchInterval: TimeInterval = 60

    init(env: AppEnvironment, problems: ProblemCenter) {
        self.env = env
        self.problems = problems
    }

    /// Points the panel at a repo: state reset, tree / history loaded, "behind" refreshed (throttled).
    func show(repo: RepoState) {
        guard repoURL != repo.url else { return }
        generation += 1
        repoURL = repo.url
        behind = nil
        tree = nil
        selectedPath = nil
        targetLine = nil
        content = nil
        query = ""
        results = []
        searchError = nil
        searchedQuery = nil
        commits = []
        Task { await loadTree() }
        Task { await loadHistory() }
        Task { await refreshBehind() }
    }

    func clear() {
        generation += 1
        repoURL = nil
    }

    // MARK: Header

    /// `git fetch` + `rev-list --count HEAD..origin/<default>`; skipped when fetched less than a minute ago.
    func refreshBehind(force: Bool = false) async {
        guard let url = repoURL, !isFetching else { return }
        if !force, let last = lastFetch[url], Date.now.timeIntervalSince(last) < Self.fetchInterval { return }
        let generation = generation
        isFetching = true
        defer { isFetching = false }
        let git = env.git
        let count = await Task.detached(priority: .utility) { () -> Int? in
            let client = await git.client(for: url)
            return try? await client.behindCount()
        }.value
        guard generation == self.generation else { return }
        lastFetch[url] = .now
        behind = count
    }

    /// `git pull --ff-only`; a diverged branch becomes a problem.
    func pull(repo: RepoState, scope: ScopeState) async {
        guard let url = repoURL, !isPulling else { return }
        isPulling = true
        defer { isPulling = false }
        let git = env.git
        do {
            try await Task.detached(priority: .userInitiated) {
                let client = await git.client(for: url)
                try await client.pullFastForward()
            }.value
            repo.refreshFacts()
            lastFetch[url] = nil
            await refreshBehind(force: true)
            await loadHistory()
            await loadTree()
        } catch {
            problems.error("Pull failed in \(repo.shortName)", detail: String(describing: error), scope: scope.id)
        }
    }

    // MARK: Files

    func loadTree() async {
        guard let url = repoURL else { return }
        let generation = generation
        let git = env.git
        let result = await Task.detached(priority: .userInitiated) { () -> Result<FileNode, any Error> in
            let client = await git.client(for: url)
            do { return .success(try await client.fileTree()) } catch { return .failure(error) }
        }.value
        guard generation == self.generation else { return }
        switch result {
        case .success(let node): tree = node
        case .failure(let error): problems.error("Could not list \(url.lastPathComponent)", detail: String(describing: error))
        }
    }

    /// Shows a file in the viewer (optionally scrolled to `line`).
    func open(path: String, line: Int? = nil) {
        guard let url = repoURL else { return }
        let generation = generation
        selectedPath = path
        targetLine = line
        content = .loading
        Task.detached(priority: .userInitiated) {
            let loaded: BaseFileContent
            do {
                let file = url.appending(path: path)
                if ImageFiles.isImage(path), let data = try ImageFiles.read(at: file) {
                    loaded = .image(data)
                } else {
                    loaded = .text(try BaseFiles.readFile(at: file))
                }
            } catch let error as BaseError {
                switch error {
                case .binaryFile: loaded = .unavailable("Binary file — not shown.")
                case .fileTooLarge(_, let bytes):
                    let limit = ImageFiles.isImage(path) ? "\(ImageFiles.maxBytes / 1_048_576) MiB" : "1 MiB"
                    loaded = .unavailable("File is larger than \(limit) (\(bytes) bytes) — not shown.")
                default: loaded = .unavailable(String(describing: error))
                }
            } catch {
                loaded = .unavailable(String(describing: error))
            }
            await MainActor.run {
                guard generation == self.generation, self.selectedPath == path else { return }
                self.content = loaded
            }
        }
    }

    // MARK: Search

    /// Runs the query with the current options; an empty query clears. A newer search drops this one's result.
    func search() async {
        guard let url = repoURL else { return }
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            clearSearch()
            return
        }
        let generation = generation
        searchGeneration += 1
        let searchGeneration = searchGeneration
        isSearching = true
        defer { if searchGeneration == self.searchGeneration { isSearching = false } }
        let git = env.git
        let options = searchOptions
        let subpath = searchSubpath.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tool = searchTool
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[SearchMatch], any Error> in
            let client = await git.client(for: url)
            do {
                return .success(try await client.search(pattern: pattern, in: subpath.isEmpty ? nil : subpath, options: options, tool: tool))
            } catch {
                return .failure(error)
            }
        }.value
        guard generation == self.generation, searchGeneration == self.searchGeneration else { return }
        searchedQuery = pattern
        switch result {
        case .success(let matches):
            results = matches
            searchError = nil
        case .failure(let error):
            results = []
            searchError = Self.searchErrorMessage(error)
        }
    }

    func clearSearch() {
        searchGeneration += 1
        isSearching = false
        results = []
        searchError = nil
        searchedQuery = nil
    }

    /// The tool's own message (regex syntax errors, unknown paths) rather than the wrapped argument dump.
    static func searchErrorMessage(_ error: any Error) -> String {
        if let git = error as? GitError {
            let stderr = git.result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { return stderr.split(separator: "\n").prefix(3).joined(separator: " ") }
        }
        return String(describing: error)
    }

    // MARK: History

    func loadHistory() async {
        guard let url = repoURL else { return }
        let generation = generation
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let git = env.git
        let loaded = await Task.detached(priority: .utility) { () -> [Commit] in
            let client = await git.client(for: url)
            return (try? await client.recentHistory(limit: 50)) ?? []
        }.value
        guard generation == self.generation else { return }
        commits = loaded
    }
}

extension AppModel {
    /// What a Base pin made now would belong to: the selected task, else the selected loose thread, else the scope.
    var baseContext: BaseContext? {
        guard let scope = currentScope else { return nil }
        if let task = currentTask { return .task(task.id) }
        if case .thread(let id) = selection { return .thread(id) }
        return .scope(scope.id)
    }

    /// The repository the Base panel shows and why (`BaseSubjectResolver`, where the rule is and is tested).
    /// A selected repo row is its own answer, so no pin applies to it.
    func baseSubject(ignoringPin: Bool = false) -> (repo: RepoState, reason: BaseSubjectReason)? {
        guard let scope = currentScope else { return nil }
        var selectedRepo: String?
        if case .repo(_, let relativePath) = selection { selectedRepo = relativePath }
        let pin = ignoringPin || selectedRepo != nil ? nil : baseContext.flatMap { base.pins[$0.key] }
        let input = BaseSubjectInput(
            scopeRoot: scope.url.path,
            repos: scope.repos.map(\.id),
            pin: pin,
            selectedRepo: selectedRepo,
            threadDirectory: currentThread.map { $0.agentDirectory ?? $0.reportedDirectory ?? $0.record.cwd },
            taskRepos: currentTask?.activeRepos ?? [],
            deltaFocus: delta.taskID == currentTask?.id ? delta.selectedFile?.repo : nil,
            recent: base.recent[scope.id]
        )
        guard let subject = BaseSubjectResolver.resolve(input),
              let repo = scope.repos.first(where: { GraphModel.key(for: $0) == subject.repo }) else { return nil }
        return (repo, subject.reason)
    }

    var baseRepo: RepoState? { baseSubject()?.repo }

    /// Points Base at `repo` for the current context, until unpinned. With a repo row selected the row is the
    /// choice, so the selection moves instead.
    func pinBase(_ repo: RepoState, in scope: ScopeState) {
        if case .repo = selection {
            selection = .repo(scope.id, relativePath: repo.id)
            return
        }
        guard let context = baseContext else { return }
        base.pins[context.key] = GraphModel.key(for: repo)
        persistUIState()
    }

    /// Lets Base follow the selection again in the current context.
    func unpinBase() {
        guard let context = baseContext, base.pins.removeValue(forKey: context.key) != nil else { return }
        persistUIState()
    }

    /// Whether a stored pin still has something to belong to (its task, thread or scope exists).
    func isLiveBaseContext(_ key: String) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        switch parts[0] {
        case "task": return TaskID(rawValue: parts[1]).flatMap(task) != nil
        case "thread": return ThreadID(rawValue: parts[1]).flatMap(session) != nil
        case "scope": return scope(ScopeID(rawValue: parts[1])) != nil
        default: return false
        }
    }

    /// Shows the Base panel for a repo (card link, sidebar "See Base", ⌘P on a base file), pinned in the current
    /// context. Closes the sheet the link may sit on: the inspector is behind it.
    func showBase(repo: RepoState, in scope: ScopeState) {
        pinBase(repo, in: scope)
        globalSheet = nil
        showInspector(.base)
    }

    /// The repos the Base header offers: the task's own first while a task is selected — the panel is about the
    /// task — then the rest of the scope; every repo of the scope otherwise.
    func baseRepoCandidates(in scope: ScopeState) -> (own: [RepoState], others: [RepoState]) {
        guard let task = currentTask else { return (scope.repos, []) }
        let keys = Set(task.activeRepos.map(\.repoRelativePath))
        return (scope.repos.filter { keys.contains(GraphModel.key(for: $0)) },
                scope.repos.filter { !keys.contains(GraphModel.key(for: $0)) })
    }

    /// "Open a shell here": a driver-less terminal in the base checkout (spec §4.5).
    func openBaseShell(repo: RepoState, in scope: ScopeState) async {
        await newThread(in: scope.id, driverID: "shell", cwdKind: .repoBase(relativePath: repo.id),
                        title: "\(repo.shortName) (base)")
    }
}
