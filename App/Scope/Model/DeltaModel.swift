import AppKit
import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Identity of a file inside a multi-repo delta.
struct DeltaFileRef: Hashable, Sendable {
    let repo: String
    let path: String
}

/// One repo of the loaded delta.
struct RepoDelta: Identifiable, Sendable {
    let repo: TaskRepo
    var delta: Delta?
    var error: String?
    var id: String { repo.repoRelativePath }
}

/// State of the Delta inspector (spec §4.4): the loaded delta per repo of the followed task, the
/// selection, folded hunks, PR URLs, and the git actions. Loading and actions run off the main actor
/// through the shared `GitClientRegistry`; failures go to the `ProblemCenter`.
@MainActor
@Observable
final class DeltaModel {
    private(set) var taskID: TaskID?
    var mode: DeltaMode = .task
    private(set) var repos: [RepoDelta] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isActing = false
    var selectedFile: DeltaFileRef?
    var collapsedHunks: Set<String> = []
    /// Hunk the keyboard moved to (`]` / `[`); the diff view scrolls to it.
    var focusedHunk: Int?
    /// PR of the current branch per repo (`prView`), looked up once per task.
    private(set) var prURLs: [String: URL] = [:]
    let gh: GhClient?

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var generation = 0

    init(env: AppEnvironment, problems: ProblemCenter) {
        self.env = env
        self.problems = problems
        self.gh = GhClient.locate()
    }

    // MARK: Derived

    var summary: DiffSummary {
        DiffSummary(repos.flatMap { $0.delta?.files ?? [] })
    }

    var ahead: Int { repos.reduce(0) { $0 + ($1.delta?.ahead ?? 0) } }
    var behind: Int { repos.reduce(0) { $0 + ($1.delta?.behind ?? 0) } }

    /// Files in list order (repo, then path).
    var orderedFiles: [DeltaFileRef] {
        repos.flatMap { repo in (repo.delta?.files ?? []).map { DeltaFileRef(repo: repo.id, path: $0.path) } }
    }

    func file(_ ref: DeltaFileRef) -> DiffFile? {
        repos.first { $0.id == ref.repo }?.delta?.files.first { $0.path == ref.path }
    }

    var selectedDiffFile: DiffFile? { selectedFile.flatMap(file) }

    func taskRepo(_ relativePath: String) -> TaskRepo? {
        repos.first { $0.id == relativePath }?.repo
    }

    /// The repo the action bar acts on: the selected file's, else the first active one.
    var focusedRepo: TaskRepo? {
        if let selectedFile, let repo = taskRepo(selectedFile.repo) { return repo }
        return repos.first?.repo
    }

    func hunkKey(_ ref: DeltaFileRef, _ index: Int) -> String { "\(ref.repo)\u{0}\(ref.path)\u{0}\(index)" }

    func isCollapsed(_ ref: DeltaFileRef, _ index: Int) -> Bool { collapsedHunks.contains(hunkKey(ref, index)) }

    func toggleHunk(_ ref: DeltaFileRef, _ index: Int) {
        let key = hunkKey(ref, index)
        if collapsedHunks.contains(key) { collapsedHunks.remove(key) } else { collapsedHunks.insert(key) }
    }

    // MARK: Keyboard

    func selectNextFile(_ step: Int) {
        let files = orderedFiles
        guard !files.isEmpty else { return }
        let index = selectedFile.flatMap { files.firstIndex(of: $0) } ?? (step > 0 ? -1 : files.count)
        let next = min(max(index + step, 0), files.count - 1)
        selectedFile = files[next]
        focusedHunk = nil
    }

    func focusHunk(_ step: Int) {
        guard let file = selectedDiffFile, !file.hunks.isEmpty else { return }
        let current = focusedHunk ?? (step > 0 ? -1 : file.hunks.count)
        focusedHunk = min(max(current + step, 0), file.hunks.count - 1)
    }

    // MARK: Loading

    /// Loads the delta of `task` in the current mode. Stale results (a newer load started) are dropped.
    func load(task: TaskState) async {
        generation += 1
        let generation = generation
        let record = task.record
        let mode = mode
        if taskID != record.id {
            taskID = record.id
            selectedFile = nil
            collapsedHunks = []
            prURLs = [:]
            repos = []
            hasLoaded = false
            Task { await lookupPRs(task: record) }
        }
        isLoading = true
        let git = env.git
        let loaded: [RepoDelta] = await Task.detached(priority: .userInitiated) {
            var result: [RepoDelta] = []
            for repo in record.activeRepos {
                let scopeRoot = URL(fileURLWithPath: record.scopeRoot, isDirectory: true)
                let base = repo.isScopeRoot ? scopeRoot : scopeRoot.appending(path: repo.repoRelativePath, directoryHint: .isDirectory)
                guard ScopeState.rootExists(repo.sandboxURL) else {
                    result.append(RepoDelta(repo: repo, error: "sandbox missing: \(repo.sandboxPath)"))
                    continue
                }
                let client = await git.client(for: base)
                do {
                    let delta = try await Delta.load(mode: mode, in: repo.sandboxURL, using: client)
                    result.append(RepoDelta(repo: repo, delta: delta))
                } catch {
                    result.append(RepoDelta(repo: repo, error: String(describing: error)))
                }
            }
            return result
        }.value
        guard generation == self.generation else { return }
        repos = loaded
        isLoading = false
        hasLoaded = true
        if let selectedFile, file(selectedFile) == nil { self.selectedFile = nil }
        if selectedFile == nil, mode != .baseVsOrigin { selectedFile = orderedFiles.first }
    }

    private func lookupPRs(task: TaskRecord) async {
        guard let gh else { return }
        for repo in task.activeRepos {
            if let url = try? await gh.prView(in: repo.sandboxURL) {
                guard taskID == task.id else { return }
                prURLs[repo.repoRelativePath] = url
            }
        }
    }

    // MARK: Actions

    /// `git add -A && git commit` in the focused repo's sandbox.
    func commit(message: String, task: TaskState) async {
        guard let repo = focusedRepo else { return }
        await act("Commit failed in \(repo.name)") { git in
            let client = await git.client(for: repo.sandboxURL)
            try await client.commitAll(message: message)
        }
        task.refresh()
        await load(task: task)
    }

    /// `git push -u origin <branch>` in the focused repo's sandbox.
    func push(task: TaskState) async {
        guard let repo = focusedRepo else { return }
        await act("Push failed in \(repo.name)") { git in
            let client = await git.client(for: repo.sandboxURL)
            try await client.push()
        }
        task.refresh()
        await load(task: task)
    }

    /// `gh pr create` in the focused repo's sandbox (pushes first when the branch has no upstream yet).
    func createPR(task: TaskState) async {
        guard let gh, let repo = focusedRepo else { return }
        let record = task.record
        let title = record.name
        let body = "Task **\(record.name)** (branch `\(record.branch)`) from scope \(record.scopeName)."
        let key = repo.repoRelativePath
        await act("Create PR failed in \(repo.name)") { git in
            let client = await git.client(for: repo.sandboxURL)
            let upstream = try await client.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: .seconds(10), allowFailure: true)
            if !upstream.succeeded { try await client.push() }
            let url = try await gh.prCreate(title: title, body: body, in: repo.sandboxURL)
            await MainActor.run { self.prURLs[key] = url }
        }
    }

    func openPR(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func act(_ failureTitle: String, _ work: @escaping @Sendable (GitClientRegistry) async throws -> Void) async {
        isActing = true
        defer { isActing = false }
        let git = env.git
        do {
            try await Task.detached(priority: .userInitiated) { try await work(git) }.value
        } catch {
            problems.error(failureTitle, detail: String(describing: error))
        }
    }

    // MARK: Patch text

    /// Unified patch of the selected file, rebuilt from the parsed hunks.
    func patchText(_ file: DiffFile) -> String {
        var lines: [String] = []
        let old = file.status == .added ? "/dev/null" : "a/\(file.oldPath ?? file.path)"
        let new = file.status == .deleted ? "/dev/null" : "b/\(file.path)"
        lines.append("diff --git a/\(file.oldPath ?? file.path) b/\(file.path)")
        lines.append("--- \(old)")
        lines.append("+++ \(new)")
        for hunk in file.hunks {
            lines.append(hunk.header)
            for line in hunk.lines {
                switch line.kind {
                case .context: lines.append(" " + line.text)
                case .addition: lines.append("+" + line.text)
                case .deletion: lines.append("-" + line.text)
                case .noNewline: lines.append("\\ No newline at end of file")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func copyPatch() {
        guard let file = selectedDiffFile else { return }
        Pasteboard.copy(patchText(file))
    }
}
