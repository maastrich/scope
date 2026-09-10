import Foundation
import ScopeCore
import ScopeGit

/// Creates, extends, archives and closes tasks (spec §4.3): one worktree per repo on the task
/// branch (see `TaskProposer`), the task root under `<home>/sandboxes/<scope-slug>/<task-slug>/`, `AGENTS.md`
/// and `<slug>.code-workspace` projected into it, the record in `<home>/tasks/<id>.json`.
///
/// Repo paths are relative to the scope root (`"api"`, `"group/web"`); `"."` means the scope
/// folder itself is the repo (repo scope, spec §2), in which case the task root *is* the sandbox.
public actor TaskManager {
    public nonisolated let home: URL
    private let registry: GitClientRegistry
    private let store: TaskRecordStore
    private var records: [TaskID: TaskRecord] = [:]
    /// Context files a projection left alone because the repository already had one of its own, per task.
    /// Read by the app after a create / addRepo / regenerate so the user hears about it once.
    private var projectionSkips: [TaskID: [String]] = [:]

    public init(home: URL, registry: GitClientRegistry, store: TaskRecordStore) {
        self.home = home
        self.registry = registry
        self.store = store
    }

    /// Names of the context files the last projection of `id` did not write, because a file of that name
    /// was already there and Scope did not generate it.
    public func projectionWarnings(for id: TaskID) -> [String] { projectionSkips[id] ?? [] }

    // MARK: - Records

    /// Loads every record from disk into the manager. Call once at startup.
    public func loadAll() async -> [StoreProblem] {
        let loaded = await store.loadAll()
        records = Dictionary(uniqueKeysWithValues: loaded.records.map { ($0.id, $0) })
        return loaded.problems
    }

    /// Every known task, oldest first.
    public var allTasks: [TaskRecord] {
        records.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func tasks(in scope: ScopeID) -> [TaskRecord] {
        allTasks.filter { $0.scopeID == scope }
    }

    public func task(_ id: TaskID) -> TaskRecord? { records[id] }

    /// `sandboxes/<scope-slug>/`
    public nonisolated func scopeSandboxesURL(scopeSlug: String) -> URL {
        ScopeHome.sandboxesURL(home: home).appending(path: scopeSlug, directoryHint: .isDirectory)
    }

    /// See `TaskRecord.threadCwd`.
    public nonisolated func threadCwd(for task: TaskRecord) -> URL { task.threadCwd }

    /// See `TaskRecord.environment` (`SCOPE_TASK`, `SCOPE_TASK_ROOT`).
    public nonisolated func taskEnvironment(for task: TaskRecord) -> [String: String] { task.environment }

    // MARK: - Create / extend

    /// Creates a task: unique slug in the scope, the given branch, one worktree per repo from
    /// `origin/<default>` (after `fetch`; local `<default>` when there is no origin), the projection
    /// files, and the record. The branch name is the caller's (a `TaskProposal`): no prefix is added.
    ///
    /// - Parameters:
    ///   - name: display name (the proposal title).
    ///   - branch: the branch to create in every sandbox; must be a valid ref name.
    ///   - slug: worktree folder name; derived from `name` when nil. `-2`, `-3`… on collision.
    ///   - initialPrompt: the request the task was created from, stored on the record and shown in `AGENTS.md`.
    ///   - scope: the declaring scope.
    ///   - repos: relative paths of the repos to sandbox (`["."]` for a repo scope).
    ///   - startPoint: what the sandboxes are based on; `.existingBranch` and `.pullRequest` continue work
    ///     that already exists, in which case `branch` must be the branch they name.
    ///   - pullRequest: the pull request to bind the record to (set together with `.pullRequest`).
    ///   - scopeRepos: relative paths of *all* repos of the scope, for the "other repos" section of `AGENTS.md`.
    /// - Throws: `TaskError`. Worktrees and branches created before a failure are removed again.
    public func create(
        name: String, branch: String, slug requestedSlug: String? = nil, initialPrompt: String? = nil,
        in scope: ScopeDeclaration, repos: [String], startPoint: TaskStartPoint = .defaultBranch,
        pullRequest: LinkedPullRequest? = nil, scopeRepos: [String] = [], repoSummaries: [RepoContextSummary] = [],
        contextFiles: [String] = [], createdBy: String? = nil
    ) async throws -> TaskRecord {
        let requested = repos.map(TaskRepo.normalize)
        guard !requested.isEmpty else { throw TaskError.invalidRepoSelection("a task needs at least one repository") }
        if requested.contains("."), requested.count > 1 {
            throw TaskError.invalidRepoSelection("a repo scope task holds the scope itself only")
        }
        // One branch, one head: a pull request lives in exactly one repository.
        if startPoint.pullRequest != nil, requested.count > 1 {
            throw TaskError.invalidRepoSelection("a task on a pull request sandboxes its repository only")
        }
        guard Set(requested).count == requested.count else { throw TaskError.invalidRepoSelection("duplicate repositories") }

        // The start point dictates the branch when it continues existing work: the branch is not a name to
        // choose, it is the one already carrying the commits.
        let branch = (startPoint.requiredBranch ?? branch).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.hasPrefix("scope/") else { throw TaskError.invalidBranch(branch) }
        let slugSource = requestedSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let slug = uniqueSlug(for: slugSource.isEmpty ? name : slugSource, in: scope)
        let root = scopeSandboxesURL(scopeSlug: scope.slug).appending(path: slug, directoryHint: .isDirectory)
        let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        var record = TaskRecord(
            scopeID: scope.id, scopeRoot: scope.path, scopeSlug: scope.slug, scopeName: scope.name,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slug : name,
            slug: slug, branch: branch, root: root.filesystemPath, createdAt: TaskRecord.roundedToMilliseconds(.now),
            pullRequest: pullRequest, prompt: (prompt?.isEmpty ?? true) ? nil : prompt, createdBy: createdBy
        )

        var created: [(TaskRepo, branchWasNew: Bool)] = []
        do {
            for path in requested {
                var (repo, isNew) = try await makeSandbox(repoRelativePath: path, task: record, startPoint: startPoint)
                repo.branchCreated = isNew
                created.append((repo, isNew))
                record.repos.append(repo)
            }
            try await writeProjection(record, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
            try await persist(record)
        } catch {
            await rollback(created, task: record)
            throw error
        }
        records[record.id] = record
        return record
    }

    /// Creates a task for an open pull request of `repo`: name `#<n> <title>`, slug `pr-<n>-<slug>`, and one
    /// sandbox on the PR's head.
    ///
    /// - Same-repository PR: the branch is `pr.headRefName`, started from `origin/<headRefName>` (fetched
    ///   first); a local branch of that name is reused as is.
    /// - Cross-repository PR (fork): `pull/<n>/head` is fetched into `refs/remotes/origin/pr/<n>` and the
    ///   local branch is `pr/<n>`. Pushing back goes to the fork, which needs its own remote — out of scope here.
    public func createForPullRequest(
        _ pr: PullRequest, in scope: ScopeDeclaration, repo: String, initialPrompt: String? = nil,
        scopeRepos: [String] = [], repoSummaries: [RepoContextSummary] = [], contextFiles: [String] = []
    ) async throws -> TaskRecord {
        let path = TaskRepo.normalize(repo)
        let name = TaskManager.taskName(forPullRequest: pr)
        let slug = uniqueSlug(for: TaskManager.taskSlug(forPullRequest: pr), in: scope)
        let branch = pr.isCrossRepository ? "pr/\(pr.number)" : pr.headRefName
        let root = scopeSandboxesURL(scopeSlug: scope.slug).appending(path: slug, directoryHint: .isDirectory)
        var record = TaskRecord(
            scopeID: scope.id, scopeRoot: scope.path, scopeSlug: scope.slug, scopeName: scope.name,
            name: name, slug: slug, branch: branch, root: root.filesystemPath,
            createdAt: TaskRecord.roundedToMilliseconds(.now),
            pullRequest: LinkedPullRequest(pr),
            prompt: initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        var created: [(TaskRepo, branchWasNew: Bool)] = []
        do {
            var (sandbox, isNew) = try await makeSandbox(repoRelativePath: path, task: record, startPoint: .pullRequest(pr))
            sandbox.branchCreated = isNew
            created.append((sandbox, isNew))
            record.repos.append(sandbox)
            try await writeProjection(record, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
            try await persist(record)
        } catch {
            await rollback(created, task: record)
            throw error
        }
        records[record.id] = record
        return record
    }

    /// `#<n> <title>` — the display name both pull-request paths give a task.
    public static func taskName(forPullRequest pr: PullRequest) -> String { "#\(pr.number) \(pr.title)" }

    /// `pr-<n>-<title slug>` — the sandbox folder both pull-request paths give a task.
    public static func taskSlug(forPullRequest pr: PullRequest) -> String {
        "pr-\(pr.number)-\(TaskBranch.slug(for: pr.title))"
    }

    /// The task bound to pull request `number` in `scope` (archived tasks included), if any.
    public func task(forPullRequest number: Int, in scope: ScopeID) -> TaskRecord? {
        tasks(in: scope).first { $0.pullRequest?.number == number }
    }

    /// Binds a pull request to an existing task (after "Create PR" on its branch).
    @discardableResult
    public func linkPullRequest(_ link: LinkedPullRequest, to id: TaskID) async throws -> TaskRecord {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        record.pullRequest = link
        try await persist(record)
        records[id] = record
        return record
    }

    /// Adds a repo to a running task: creates the missing sandbox, regenerates the projection.
    public func addRepo(_ id: TaskID, repo: String, scopeRepos: [String] = [], repoSummaries: [RepoContextSummary] = [],
                        contextFiles: [String] = []) async throws -> TaskRecord {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        guard !record.isArchived else { throw TaskError.taskArchived }
        let path = TaskRepo.normalize(repo)
        if path == "." || record.isMonoRepo {
            throw TaskError.invalidRepoSelection("a repo scope task holds the scope itself only")
        }
        guard record.repo(at: path) == nil else { throw TaskError.repoAlreadyInTask(repo: path) }

        let (sandbox, isNew) = try await makeSandbox(repoRelativePath: path, task: record)
        record.repos.append(sandbox)
        do {
            try await writeProjection(record, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
            try await persist(record)
        } catch {
            await rollback([(sandbox, isNew)], task: record)
            throw error
        }
        records[id] = record
        return record
    }

    /// Rewrites `AGENTS.md` and the `.code-workspace` (after a Graph refresh, or a repo list change).
    public func regenerateProjection(_ id: TaskID, scopeRepos: [String] = [], repoSummaries: [RepoContextSummary] = [],
                                     contextFiles: [String] = []) async throws {
        guard let record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        try await writeProjection(record, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
    }

    // MARK: - Archive / close

    /// Removes every sandbox but keeps the branches; the record stays, marked archived.
    /// Guardrail: `TaskError.uncommittedChanges` on the first dirty sandbox unless `force`. Nothing is
    /// removed before every sandbox passed the check.
    @discardableResult
    public func archive(_ id: TaskID, force: Bool = false) async throws -> TaskRecord {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        try await guardClean(record, force: force)
        for index in record.repos.indices where record.repos[index].state == .active {
            try await removeSandbox(record.repos[index], task: record, force: force)
            record.repos[index].state = .archived
        }
        removeRootIfNotSandbox(record)
        record.archivedAt = TaskRecord.roundedToMilliseconds(.now)
        try await persist(record)
        records[id] = record
        return record
    }

    /// Removes every sandbox and the record; deletes the local branches when `deleteBranch`.
    ///
    /// Guardrails: `TaskError.uncommittedChanges` for a dirty sandbox and `TaskError.branchNotMerged`
    /// for an unmerged branch (`git branch -d`), both bypassed by `force` (`-D`) once the user confirmed.
    public func close(_ id: TaskID, deleteBranch: Bool, force: Bool = false) async throws {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        try await guardClean(record, force: force)
        for index in record.repos.indices where record.repos[index].state == .active {
            try await removeSandbox(record.repos[index], task: record, force: force)
            record.repos[index].state = .archived
        }
        removeRootIfNotSandbox(record)
        if deleteBranch {
            for repo in record.repos {
                let client = try await baseClient(for: repo.repoRelativePath, task: record)
                do {
                    try await client.deleteBranch(name: repo.branch, force: force)
                } catch let error as GitError {
                    if !force, error.message.contains("not fully merged") {
                        // Sandboxes are gone but the record stays so the user can retry with force.
                        try? await persist(record)
                        records[id] = record
                        throw TaskError.branchNotMerged(repo: repo.repoRelativePath, branch: repo.branch)
                    }
                    if !error.message.contains("not found") {
                        throw TaskError.git(repo: repo.repoRelativePath, error)
                    }
                }
            }
        }
        do { try await store.delete(id) } catch { throw TaskError.persistence(String(describing: error)) }
        records[id] = nil
    }

    /// `git worktree prune` on each base checkout (spec §4.3: at startup). Failures are logged, never thrown.
    public func pruneWorktrees(in scope: ScopeDeclaration, repos: [String]) async {
        for path in repos {
            let base = Self.baseURL(scopeRoot: scope.path, repoRelativePath: TaskRepo.normalize(path))
            let client = await registry.client(for: base)
            do { try await client.prune() } catch { Log.tasks.error("prune failed in \(base.path): \(String(describing: error))") }
        }
    }

    // MARK: - Internals

    /// `<root>/<slug>` plus `-2`, `-3`… while a record of the scope or a folder under `sandboxes/<scope>/` uses it.
    private func uniqueSlug(for name: String, in scope: ScopeDeclaration) -> String {
        var taken = Set(tasks(in: scope.id).map(\.slug))
        if let folders = try? FileManager.default.contentsOfDirectory(atPath: scopeSandboxesURL(scopeSlug: scope.slug).path) {
            taken.formUnion(folders)
        }
        return SlugAllocator.unique(base: TaskBranch.slug(for: name), taken: taken)
    }

    static func baseURL(scopeRoot: String, repoRelativePath: String) -> URL {
        let root = URL(fileURLWithPath: scopeRoot, isDirectory: true)
        return repoRelativePath == "." ? root : root.appending(path: repoRelativePath, directoryHint: .isDirectory)
    }

    private func baseClient(for repoRelativePath: String, task: TaskRecord) async throws -> GitClient {
        let base = Self.baseURL(scopeRoot: task.scopeRoot, repoRelativePath: repoRelativePath)
        guard RepoDiscovery.gitKind(at: base) != nil else { throw TaskError.repoNotFound(repo: repoRelativePath) }
        return await registry.client(for: base)
    }

    /// Fetch, resolve the start point, add the worktree. Returns the repo entry and whether the branch was created.
    ///
    /// `startPoint` decides what the worktree is based on: a new branch off the repository's base
    /// (`.defaultBranch`), an existing branch, or a pull request's head (see `createForPullRequest`).
    private func makeSandbox(
        repoRelativePath path: String, task: TaskRecord, startPoint requested: TaskStartPoint = .defaultBranch
    ) async throws -> (TaskRepo, Bool) {
        let client = try await baseClient(for: path, task: task)
        let sandbox = path == "." ? task.rootURL : task.rootURL.appending(path: path, directoryHint: .isDirectory)

        let hasOrigin = await client.hasRemote("origin")
        if hasOrigin {
            do { try await client.fetch(remote: "origin") } catch {
                // Continuing existing work needs origin's refs. A plain task falls back to the local ones.
                guard !requested.continuesExistingWork else {
                    if let error = error as? GitError { throw TaskError.git(repo: path, error) }
                    throw TaskError.persistence("fetch failed in \(path): \(String(describing: error))")
                }
                Log.tasks.warning("fetch failed in \(path): \(String(describing: error)); using the local origin/<default>")
            }
        }
        let startPoint: String
        switch requested {
        case .pullRequest(let pullRequest):
            let ref: String
            if pullRequest.isCrossRepository {
                ref = "origin/pr/\(pullRequest.number)"
                do {
                    try await client.fetch(remote: "origin", refspecs: ["+pull/\(pullRequest.number)/head:refs/remotes/\(ref)"])
                } catch let error as GitError {
                    throw TaskError.git(repo: path, error)
                }
            } else {
                ref = "origin/\(pullRequest.headRefName)"
            }
            guard await client.refExists(ref) else { throw TaskError.pullRequestHeadMissing(repo: path, ref: ref) }
            startPoint = ref
        case .existingBranch(let name):
            // The local branch wins (that is the work being continued); origin's copy is the fallback.
            if await client.branchExists(name) {
                startPoint = name
            } else if await client.refExists("origin/\(name)") {
                startPoint = "origin/\(name)"
            } else {
                throw TaskError.branchNotFound(repo: path, branch: name)
            }
        case .defaultBranch:
            guard let defaultBranch = await client.defaultBranch() else { throw TaskError.noDefaultBranch(repo: path) }
            startPoint = await client.refExists("origin/\(defaultBranch)") ? "origin/\(defaultBranch)" : defaultBranch
        }
        let branchWasNew = !(await client.branchExists(task.branch))
        if !branchWasNew, let checkout = await client.worktreePath(ofBranch: task.branch) {
            throw TaskError.branchAlreadyCheckedOut(repo: path, branch: task.branch, path: checkout)
        }

        do {
            try await client.createWorktree(at: sandbox, branch: task.branch, from: startPoint)
        } catch let error as GitError {
            throw TaskError.git(repo: path, error)
        } catch let error as WorktreeError {
            throw TaskError.worktree(repo: path, error)
        }
        let repo = TaskRepo(repoRelativePath: path, sandboxPath: sandbox.filesystemPath, branch: task.branch)
        return (repo, branchWasNew)
    }

    private func rollback(_ created: [(TaskRepo, branchWasNew: Bool)], task: TaskRecord) async {
        for (repo, branchWasNew) in created {
            guard let client = try? await baseClient(for: repo.repoRelativePath, task: task) else { continue }
            try? await client.removeWorktree(at: repo.sandboxURL, force: true)
            if branchWasNew { try? await client.deleteBranch(name: repo.branch, force: true) }
        }
        removeRootIfNotSandbox(task)
    }

    private func guardClean(_ record: TaskRecord, force: Bool) async throws {
        guard !force else { return }
        for repo in record.activeRepos where FileManager.default.fileExists(atPath: repo.sandboxPath) {
            let client = try await baseClient(for: repo.repoRelativePath, task: record)
            let dirty: Bool
            do { dirty = try await client.hasUncommittedChanges(at: repo.sandboxURL) }
            catch let error as GitError { throw TaskError.git(repo: repo.repoRelativePath, error) }
            if dirty { throw TaskError.uncommittedChanges(repo: repo.repoRelativePath) }
        }
    }

    private func removeSandbox(_ repo: TaskRepo, task: TaskRecord, force: Bool) async throws {
        let client = try await baseClient(for: repo.repoRelativePath, task: task)
        do {
            try await client.removeWorktree(at: repo.sandboxURL, force: force)
        } catch let error as WorktreeError {
            throw TaskError.worktree(repo: repo.repoRelativePath, error)
        } catch let error as GitError {
            throw TaskError.git(repo: repo.repoRelativePath, error)
        }
    }

    /// Deletes the task root (projection files, empty folders) — never when the root is itself a sandbox.
    private func removeRootIfNotSandbox(_ record: TaskRecord) {
        guard !record.isMonoRepo else { return }
        try? FileManager.default.removeItem(at: record.rootURL)
    }

    private func persist(_ record: TaskRecord) async throws {
        do { try await store.save(record) } catch { throw TaskError.persistence(String(describing: error)) }
    }

    /// Writes the context file under every name the drivers read, where the task's threads start, plus
    /// `<slug>.code-workspace` in the task root.
    ///
    /// The name is a property of the *driver*, not of the task — a task's threads can run Claude Code
    /// (`CLAUDE.md`) and Codex (`AGENTS.md`) side by side — so every declared name is written, all with the
    /// same content. A file Scope did not generate is never touched; its name is recorded in
    /// `projectionWarnings` instead, because an agent starting without its context is worth saying out loud.
    ///
    /// Inside a sandbox the file is listed in `.git/info/exclude`, so the delta stays clean (spec §4.6).
    /// Adding a second repository moves the thread cwd from the sandbox up to the task root: the copies
    /// left behind are removed, so the agent can never read a stale one.
    private func writeProjection(_ record: TaskRecord, scopeRepos: [String], repoSummaries: [RepoContextSummary],
                                 contextFiles: [String]) async throws {
        let others = scopeRepos.map(TaskRepo.normalize).filter { $0 != "." }
        let markdown = TaskProjection.agentsMarkdown(task: record, otherRepos: others, scopeName: record.scopeName, repoSummaries: repoSummaries)
        let names = Self.contextFileNames(contextFiles)
        let directory = record.threadCwd
        // The thread starts inside a worktree whenever the cwd is a sandbox (always, for a repo scope).
        let sandbox = record.activeRepos.first { $0.sandboxURL.filesystemPath == directory.filesystemPath }
        var skipped: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                let file = directory.appending(path: name, directoryHint: .notDirectory)
                if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.hasPrefix(TaskProjection.generatedMarker) {
                    skipped.append(name)
                    continue
                }
                try markdown.write(to: file, atomically: true, encoding: .utf8)
                if let sandbox { try await excludeFromGit(name, in: sandbox, task: record) }
            }
            try await removeGeneratedContextFiles(names, outside: directory, task: record)
            if !record.isMonoRepo {
                try TaskProjection.workspaceJSON(task: record).write(to: record.workspaceURL, options: [.atomic])
            }
        } catch let error as TaskError {
            throw error
        } catch {
            throw TaskError.persistence("projection write failed: \(String(describing: error))")
        }
        projectionSkips[record.id] = skipped
    }

    /// `AGENTS.md` first, then the other names the drivers declare, deduplicated: the pivot file is written
    /// even when no profile mentions it, so a driver Scope knows nothing about still finds something.
    static func contextFileNames(_ declared: [String]) -> [String] {
        var names = [TaskRecord.pivotContextFile]
        for raw in declared {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A name is a file in the task's own directory, never a path out of it.
            guard !name.isEmpty, !name.contains("/"), name != "." , name != "..", !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// Deletes the generated context files of a task that sit somewhere the threads no longer start.
    private func removeGeneratedContextFiles(_ names: [String], outside directory: URL, task: TaskRecord) async throws {
        var stale: [URL] = [task.rootURL]
        stale.append(contentsOf: task.repos.map(\.sandboxURL))
        for base in stale where base.filesystemPath != directory.filesystemPath {
            for name in names {
                let file = base.appending(path: name, directoryHint: .notDirectory)
                guard let existing = try? String(contentsOf: file, encoding: .utf8),
                      existing.hasPrefix(TaskProjection.generatedMarker) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Appends `name` to the repo's `info/exclude` (resolved with `git rev-parse --git-path`, so it
    /// works from a worktree where `.git` is a file) unless already listed.
    private func excludeFromGit(_ name: String, in repo: TaskRepo, task: TaskRecord) async throws {
        let client = try await baseClient(for: repo.repoRelativePath, task: task)
        let sandbox = repo.sandboxPath
        let raw: String
        do { raw = try await client.output(["-C", sandbox, "rev-parse", "--git-path", "info/exclude"]) }
        catch let error as GitError { throw TaskError.git(repo: repo.repoRelativePath, error) }
        let exclude = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: sandbox, isDirectory: true).appending(path: raw, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        let listed = existing.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == name || $0.trimmingCharacters(in: .whitespaces) == "/\(name)" }
        guard !listed else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += "/\(name)\n"
        try updated.write(to: exclude, atomically: true, encoding: .utf8)
    }
}
