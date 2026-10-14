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
    private let ports: Range<Int>
    /// Stops the processes left under a task's folders (`ProcessSweep.stop`); a stub in tests that must not kill.
    private let sweep: @Sendable ([URL]) async -> ProcessSweep.Result
    private var records: [TaskID: TaskRecord] = [:]
    /// The dismantle running for a task, so a second request joins it instead of racing it (`dismantle`).
    private var dismantling: [TaskID: (token: UUID, mode: DismantleMode, run: Task<DismantleOutcome, any Error>)] = [:]
    /// Read by the app after a create / addRepo / regenerate so the user hears about it once.

    /// - Parameter ports: where `SCOPE_PORT` blocks come from (`PortAllocator.range(debugBuild:)` in the app).
    public init(home: URL, registry: GitClientRegistry, store: TaskRecordStore,
                ports: Range<Int> = PortAllocator.range,
                sweep: @escaping @Sendable ([URL]) async -> ProcessSweep.Result = { await ProcessSweep.stop(under: $0) }) {
        self.ports = ports
        self.sweep = sweep
        self.home = home
        self.registry = registry
        self.store = store
    }


    // MARK: - Records

    /// Loads every record from disk into the manager. Call once at startup.
    ///
    /// A setup still marked running was cut short by a quit and is reported as failed; a live task written before
    /// ports were handed out gets its block now. Both are saved at once so the answer never changes.
    public func loadAll() async -> [StoreProblem] {
        let loaded = await store.loadAll()
        records = Dictionary(uniqueKeysWithValues: loaded.records.map { ($0.id, $0) })
        for original in allTasks {
            var record = original
            if let setup = record.setup { record.setup = setup.normalizedAfterRestart }
            if record.portBase == nil, !record.isArchived { record.portBase = allocatePort(excluding: record.id) }
            guard record != original else { continue }
            records[record.id] = record
            try? await persist(record)
        }
        return loaded.problems
    }

    /// A free block for a new live task: archived tasks give theirs back.
    private func allocatePort(excluding id: TaskID? = nil) -> Int? {
        PortAllocator.allocate(taken: records.values.filter { !$0.isArchived && $0.id != id }.compactMap(\.portBase),
                               in: ports)
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
            pullRequest: pullRequest, prompt: (prompt?.isEmpty ?? true) ? nil : prompt, createdBy: createdBy,
            portBase: allocatePort()
        )

        var created: [(TaskRepo, branchWasNew: Bool)] = []
        do {
            for path in requested {
                var (repo, isNew) = try await makeSandbox(repoRelativePath: path, task: record, startPoint: startPoint)
                repo.branchCreated = isNew
                created.append((repo, isNew))
                record.repos.append(repo)
            }
            try await writeProjection(record, scopeContext: scope.context, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
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
            prompt: initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            portBase: allocatePort()
        )
        var created: [(TaskRepo, branchWasNew: Bool)] = []
        do {
            var (sandbox, isNew) = try await makeSandbox(repoRelativePath: path, task: record, startPoint: .pullRequest(pr))
            sandbox.branchCreated = isNew
            created.append((sandbox, isNew))
            record.repos.append(sandbox)
            try await writeProjection(record, scopeContext: scope.context, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
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
    public func addRepo(_ id: TaskID, repo: String, scopeContext: String? = nil, scopeRepos: [String] = [],
                        repoSummaries: [RepoContextSummary] = [], contextFiles: [String] = []) async throws -> TaskRecord {
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
            try await writeProjection(record, scopeContext: scopeContext, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
            try await persist(record)
        } catch {
            await rollback([(sandbox, isNew)], task: record)
            throw error
        }
        records[id] = record
        return record
    }

    /// Rewrites `AGENTS.md` and the `.code-workspace` (after a Graph refresh, or a repo list change).
    public func regenerateProjection(_ id: TaskID, scopeContext: String? = nil, scopeRepos: [String] = [],
                                     repoSummaries: [RepoContextSummary] = [], contextFiles: [String] = []) async throws {
        guard let record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        try await writeProjection(record, scopeContext: scopeContext, scopeRepos: scopeRepos, repoSummaries: repoSummaries, contextFiles: contextFiles)
    }

    // MARK: - Setup / teardown

    /// Prepares the sandboxes of a task (spec §4.3): copies the base checkouts' untracked files (`.env*`) into
    /// them, then runs each repository's setup command in its sandbox, one after the other. The state and the
    /// output land on the record, which is saved when the run starts and when it ends; `onChange` hears both.
    ///
    /// `runCommands: false` copies the files and marks the setup skipped. `only` limits the run to some
    /// repositories — a repository added to a running task. A failing command does not stop the others: the
    /// repositories are independent, and one log with every failure beats rerunning to find the next.
    @discardableResult
    public func runSetup(
        _ id: TaskID, commands: [String: SandboxCommands], runCommands: Bool, runner: any SandboxCommandRunner,
        only: [String]? = nil, timeout: Duration = .seconds(1800),
        onChange: @escaping @Sendable (TaskRecord) async -> Void = { _ in }
    ) async throws -> TaskRecord {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        guard !record.isArchived else { throw TaskError.taskArchived }
        let repos = record.activeRepos.filter { only?.map(TaskRepo.normalize).contains($0.repoRelativePath) ?? true }
        let willRun = runCommands && repos.contains { commands[$0.repoRelativePath]?.setup != nil }
        record.setup = TaskSetupRecord(state: willRun ? .running : .skipped, startedAt: TaskRecord.roundedToMilliseconds(.now))
        try await persist(record)
        records[id] = record
        await onChange(record)

        var log = ""
        var ran = false
        var failed = false
        for repo in repos {
            let repoCommands = commands[repo.repoRelativePath] ?? SandboxCommands()
            let base = Self.baseURL(scopeRoot: record.scopeRoot, repoRelativePath: repo.repoRelativePath)
            let name = repo.isScopeRoot ? record.scopeName : repo.repoRelativePath
            let plan = SandboxFileCopy.plan(globs: repoCommands.copyFiles, base: base, sandbox: repo.sandboxURL)
            let (copied, copyFailures) = SandboxFileCopy.apply(plan)
            for path in copied {
                log += "[\(name)] copied \(path) from the base checkout\n"
                // A file the repository does not ignore would otherwise be one `git add -A` away from a commit.
                if let client = try? await baseClient(for: repo.repoRelativePath, task: record),
                   let check = try? await client.run(["-C", repo.sandboxPath, "check-ignore", "-q", path],
                                                     timeout: .seconds(10), allowFailure: true),
                   !check.succeeded {
                    try? await excludeFromGit(path, in: repo, task: record)
                }
            }
            for refusal in plan.refusals + copyFailures {
                log += "[\(name)] did not copy \(refusal.path): \(refusal.reason)\n"
            }
            guard runCommands, let command = repoCommands.setup else { continue }
            ran = true
            let client = try? await baseClient(for: repo.repoRelativePath, task: record)
            let environment = SandboxEnvironment.variables(task: record, repo: repo, basePath: base.filesystemPath,
                                                           defaultBranch: await client?.defaultBranch())
            log += "[\(name)] $ \(command)\n"
            let outcome = await runner.run(command, in: repo.sandboxURL, environment: environment, timeout: timeout)
            if !outcome.output.isEmpty { log += outcome.output.hasSuffix("\n") ? outcome.output : outcome.output + "\n" }
            log += "[\(name)] \(outcome.succeeded ? "done" : "failed: \(outcome.summary)")\n"
            failed = failed || !outcome.succeeded
            log = SetupLog.bounded(log)
        }

        // The task may have been closed or archived while the commands ran.
        guard var current = records[id] else { throw TaskError.persistence("task \(id) went away during its setup") }
        current.setup = TaskSetupRecord(
            state: !ran ? .skipped : (failed ? .failed : .succeeded), log: SetupLog.bounded(log),
            startedAt: record.setup?.startedAt, finishedAt: TaskRecord.roundedToMilliseconds(.now)
        )
        try await persist(current)
        records[id] = current
        await onChange(current)
        return current
    }

    /// How the sandboxes of a task are torn down before they are removed.
    public struct Teardown: Sendable {
        public var commands: [String: SandboxCommands]
        public var runner: any SandboxCommandRunner
        public var timeout: Duration

        public init(commands: [String: SandboxCommands], runner: any SandboxCommandRunner, timeout: Duration = .seconds(600)) {
            self.commands = commands
            self.runner = runner
            self.timeout = timeout
        }
    }

    /// Runs the teardown command of every active sandbox that has one. A failure does not stop the dismantle:
    /// whatever the command was meant to stop is what the process sweep catches next. It comes back as a notice.
    private func runTeardown(_ record: TaskRecord, _ teardown: Teardown?) async -> [DismantleNotice] {
        guard let teardown else { return [] }
        var notices: [DismantleNotice] = []
        for repo in record.activeRepos where FileManager.default.fileExists(atPath: repo.sandboxPath) {
            guard let command = teardown.commands[repo.repoRelativePath]?.teardown else { continue }
            let base = Self.baseURL(scopeRoot: record.scopeRoot, repoRelativePath: repo.repoRelativePath)
            let client = try? await baseClient(for: repo.repoRelativePath, task: record)
            let environment = SandboxEnvironment.variables(task: record, repo: repo, basePath: base.filesystemPath,
                                                           defaultBranch: await client?.defaultBranch())
            let outcome = await teardown.runner.run(command, in: repo.sandboxURL, environment: environment, timeout: teardown.timeout)
            if !outcome.succeeded {
                notices.append(.teardownFailed(repo: repo.repoRelativePath, summary: outcome.summary,
                                               log: SetupLog.bounded("$ \(command)\n" + outcome.output)))
            }
        }
        return notices
    }

    // MARK: - Archive / close

    /// Removes every sandbox but keeps the branches; the record stays, marked archived. See `dismantle`.
    @discardableResult
    public func archive(_ id: TaskID, teardown: Teardown? = nil) async throws -> TaskRecord {
        guard let record = try await dismantle(id, .archive, teardown: teardown).record else {
            throw TaskError.persistence("unknown task \(id)")
        }
        return record
    }

    /// Removes every sandbox and the record; deletes the local branches when `deleteBranch`. See `dismantle`.
    public func close(_ id: TaskID, deleteBranch: Bool, teardown: Teardown? = nil) async throws {
        try await dismantle(id, .close(deleteBranch: deleteBranch), teardown: teardown)
    }

    /// The one path that takes a task apart — archive, close, a Retry and the GC all come through here.
    ///
    /// One run per task at a time: a second request for the same mode joins the running one (a double click, the
    /// CLI racing the UI), another mode waits for it and starts from what it left. Every step is persisted as it
    /// completes and the record carries `cleanup` until the end, so a run cut short resumes instead of finding
    /// half a task. Running it on a task that is already archived (or already gone, for a close) does nothing.
    ///
    /// Steps: `prepare` (the app hangs up the task's threads and cancels its setup), the teardown commands, the
    /// process sweep, the salvage of uncommitted changes, the worktrees, the task root, then the branches and the
    /// record for a close. Nothing asks and nothing refuses: what could be lost is saved under
    /// `refs/scope/salvage/` first (`DismantleNotice.changesSaved`, `.branchSaved`).
    @discardableResult
    public func dismantle(_ id: TaskID, _ mode: DismantleMode, teardown: Teardown? = nil,
                          prepare: (@Sendable () async -> Void)? = nil) async throws -> DismantleOutcome {
        while let running = dismantling[id] {
            if running.mode == mode { return try await running.run.value }
            _ = try? await running.run.value
        }
        let token = UUID()
        // The run clears its own entry before it completes, so a waiter never sees a finished run still listed.
        let run = Task {
            defer { finishDismantle(id, token: token) }
            return try await runDismantle(id, mode, teardown: teardown, prepare: prepare)
        }
        dismantling[id] = (token, mode, run)
        return try await run.value
    }

    private func finishDismantle(_ id: TaskID, token: UUID) {
        if dismantling[id]?.token == token { dismantling[id] = nil }
    }

    private func runDismantle(_ id: TaskID, _ mode: DismantleMode, teardown: Teardown?,
                              prepare: (@Sendable () async -> Void)?) async throws -> DismantleOutcome {
        guard var record = records[id] else {
            if mode.isClose { return DismantleOutcome(record: nil) }
            throw TaskError.persistence("unknown task \(id)")
        }
        if mode == .archive, record.isArchived, record.cleanup == nil { return DismantleOutcome(record: record) }

        record.cleanup = PendingCleanup(mode: mode, since: record.cleanup?.since ?? TaskRecord.roundedToMilliseconds(.now))
        try await save(record)
        do {
            await prepare?()
            var notices = await runTeardown(record, teardown)
            let swept = await sweep([record.rootURL])
            if !swept.survivors.isEmpty { notices.append(.processesSurvived(swept.survivors.map(\.description))) }
            for index in record.repos.indices where record.repos[index].state == .active {
                // Saved and written down before the folder goes, so a failure in between never loses it.
                if let ref = try await salvage(record.repos[index], task: record) {
                    record.repos[index].salvageRef = ref
                    try await save(record)
                    notices.append(.changesSaved(repo: record.repos[index].repoRelativePath, ref: ref))
                }
                try await removeSandbox(record.repos[index], task: record)
                record.repos[index].state = .archived
                try await save(record)
            }
            try removeRoot(record)
            emptyTrashInBackground()

            if case .close(let deleteBranch) = mode {
                if deleteBranch { notices += try await deleteBranches(record) }
                do { try await store.delete(id) } catch { throw TaskError.persistence(String(describing: error)) }
                records[id] = nil
                return DismantleOutcome(record: nil, notices: notices, stoppedProcesses: swept.stopped.map(\.description))
            }
            record.archivedAt = record.archivedAt ?? TaskRecord.roundedToMilliseconds(.now)
            record.cleanup = nil
            try await save(record)
            return DismantleOutcome(record: record, notices: notices, stoppedProcesses: swept.stopped.map(\.description))
        } catch {
            // Whatever was removed is already on the record; the failure goes on it too, for the next attempt.
            record.cleanup?.error = String(describing: error)
            try? await save(record)
            throw error
        }
    }

    /// Deletes the task branch in every repo. A branch git calls unmerged (a squash merge looks like that too)
    /// is deleted all the same once its last commit is kept under `refs/scope/salvage/`.
    private func deleteBranches(_ record: TaskRecord) async throws -> [DismantleNotice] {
        var notices: [DismantleNotice] = []
        for repo in record.repos {
            let client = try await baseClient(for: repo.repoRelativePath, task: record)
            do {
                try await client.deleteBranch(name: repo.branch)
            } catch let error as GitError where error.message.contains("not fully merged") {
                let ref = Self.salvageRef(for: record, kind: "branch")
                do {
                    try await client.run(["update-ref", ref, "refs/heads/\(repo.branch)"])
                    try await client.deleteBranch(name: repo.branch, force: true)
                } catch let error as GitError {
                    throw TaskError.git(repo: repo.repoRelativePath, error)
                }
                notices.append(.branchSaved(repo: repo.repoRelativePath, branch: repo.branch, ref: ref))
            } catch let error as GitError where error.message.contains("not found") {
                continue
            } catch let error as GitError {
                throw TaskError.git(repo: repo.repoRelativePath, error)
            }
        }
        return notices
    }

    /// `refs/scope/salvage/<slug>-<id>/<kind>`: shared by every worktree of the repository, so it outlives the
    /// sandbox, and out of `git branch` and `git stash list`.
    static func salvageRef(for record: TaskRecord, kind: String) -> String {
        "\(salvageNamespace)/\(record.slug)-\(record.id.rawValue)/\(kind)"
    }

    static let salvageNamespace = "refs/scope/salvage"

    /// Commits the sandbox's tracked and untracked changes (ignored files excluded) through a private index — the
    /// sandbox's own index and the shared stash stay untouched — and points a salvage ref at the commit.
    /// `nil` when the sandbox is clean or already gone.
    private func salvage(_ repo: TaskRepo, task: TaskRecord) async throws -> String? {
        guard FileManager.default.fileExists(atPath: repo.sandboxPath) else { return nil }
        let client = await registry.client(for: repo.sandboxURL)
        let sandbox = repo.sandboxURL.filesystemPath
        do {
            guard try await client.hasUncommittedChanges(at: repo.sandboxURL) else { return nil }
            let index = FileManager.default.temporaryDirectory.appending(path: "scope-salvage-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: index) }
            let environment = ["GIT_INDEX_FILE": index.path,
                               "GIT_AUTHOR_NAME": "Scope", "GIT_AUTHOR_EMAIL": "scope@localhost",
                               "GIT_COMMITTER_NAME": "Scope", "GIT_COMMITTER_EMAIL": "scope@localhost"]
            try await client.run(["-C", sandbox, "read-tree", "HEAD"], environment: environment)
            try await client.run(["-C", sandbox, "add", "-A"], environment: environment, timeout: .seconds(600))
            let tree = try await client.run(["-C", sandbox, "write-tree"], environment: environment)
                .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = "Scope: uncommitted changes of \(task.name) (\(repo.repoRelativePath)) when its sandbox was removed"
            let commit = try await client.run(["-C", sandbox, "commit-tree", tree, "-p", "HEAD", "-m", message],
                                              environment: environment)
                .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = Self.salvageRef(for: task, kind: "changes")
            try await client.run(["-C", sandbox, "update-ref", ref, commit])
            return ref
        } catch let error as GitError {
            throw TaskError.git(repo: repo.repoRelativePath, error)
        }
    }

    /// Brings an archived task back where it was: one worktree per repository on the branch it kept, and the
    /// changes saved when it was archived put back as uncommitted changes. The app rewrites the context files.
    @discardableResult
    public func reopen(_ id: TaskID) async throws -> TaskRecord {
        guard var record = records[id] else { throw TaskError.persistence("unknown task \(id)") }
        guard record.isArchived, record.cleanup == nil else { return record }
        var created: [(TaskRepo, branchWasNew: Bool)] = []
        do {
            for index in record.repos.indices {
                let repo = record.repos[index]
                let (sandbox, isNew) = try await makeSandbox(repoRelativePath: repo.repoRelativePath, task: record,
                                                             startPoint: .existingBranch(repo.branch))
                created.append((sandbox, isNew))
                if let ref = repo.salvageRef {
                    let client = await registry.client(for: sandbox.sandboxURL)
                    do {
                        try await client.run(["-C", sandbox.sandboxURL.filesystemPath, "restore", "--source=\(ref)",
                                              "--worktree", "--", "."], timeout: .seconds(600))
                    } catch let error as GitError {
                        throw TaskError.git(repo: repo.repoRelativePath, error)
                    }
                }
                record.repos[index].state = .active
                record.repos[index].sandboxPath = sandbox.sandboxPath
                record.repos[index].salvageRef = nil
            }
        } catch {
            await rollback(created, task: record)
            throw error
        }
        record.archivedAt = nil
        record.portBase = allocatePort(excluding: id)
        try await save(record)
        return record
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

    /// Moves the worktree into the trash and drops git's record of it. A rename never trips on what git
    /// refuses to remove (submodules, a lock, files a process wrote a moment ago) and never times out on a
    /// sandbox of several gigabytes; the uncommitted-changes guardrail has already run.
    private func removeSandbox(_ repo: TaskRepo, task: TaskRecord) async throws {
        let client = try await baseClient(for: repo.repoRelativePath, task: task)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: repo.sandboxPath) {
            let admin = Self.worktreeAdminDirectory(of: repo.sandboxURL)
            let trash = ScopeHome.trashURL(home: home)
            let destination = trash.appending(path: "\(UUID().uuidString)-\(repo.sandboxURL.lastPathComponent)")
            do {
                try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
                try fileManager.moveItem(at: repo.sandboxURL, to: destination)
            } catch {
                throw TaskError.persistence("could not remove \(repo.sandboxPath): \(error.localizedDescription)")
            }
            // `prune` skips a locked worktree even when its folder is gone.
            if let admin { try? fileManager.removeItem(at: admin.appending(path: "locked")) }
        }
        do { try await client.prune() } catch let error as GitError {
            throw TaskError.git(repo: repo.repoRelativePath, error)
        }
    }

    /// `<base>/.git/worktrees/<name>`, read from the worktree's `.git` file (`gitdir: …`).
    static func worktreeAdminDirectory(of sandbox: URL) -> URL? {
        guard let text = try? String(contentsOf: sandbox.appending(path: ".git"), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
            : sandbox.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
    }

    /// Deletes everything in the trash. The launch GC calls it too, for what a quit interrupted.
    public nonisolated func emptyTrash() {
        let trash = ScopeHome.trashURL(home: home)
        let fileManager = FileManager.default
        for item in (try? fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [] {
            do { try fileManager.removeItem(at: item) } catch {
                Log.tasks.error("could not empty \(item.path): \(String(describing: error))")
            }
        }
    }

    private nonisolated func emptyTrashInBackground() {
        Task.detached(priority: .background) { [self] in emptyTrash() }
    }

    /// Deletes the task root (projection files, empty folders) — for a one-repository scope the root is the
    /// sandbox and is already gone. Something left behind (a process that wrote into it) is a failure, not a shrug.
    private func removeRoot(_ record: TaskRecord) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: record.rootURL.path) else { return }
        do { try fileManager.removeItem(at: record.rootURL) } catch {
            throw TaskError.persistence("could not remove \(record.root): \(error.localizedDescription)")
        }
    }

    /// Rollback after a failed create: best effort, the create's own error is the one reported.
    private func removeRootIfNotSandbox(_ record: TaskRecord) {
        guard !record.isMonoRepo else { return }
        try? FileManager.default.removeItem(at: record.rootURL)
    }

    /// `persist`, and the in-memory copy with it.
    private func save(_ record: TaskRecord) async throws {
        try await persist(record)
        records[record.id] = record
    }

    private func persist(_ record: TaskRecord) async throws {
        do { try await store.save(record) } catch { throw TaskError.persistence(String(describing: error)) }
    }

    /// Writes the context file under every name the drivers read, where the task's threads start, plus
    /// `<slug>.code-workspace` in the task root.
    ///
    /// The name is a property of the *driver*, not of the task — a task's threads can run Claude Code
    /// (`CLAUDE.md`) and Codex (`AGENTS.md`) side by side — so every declared name is written, all with the
    /// same content. A file Scope did not generate is the repository's own and is never touched: where the
    /// driver reads a companion alongside it (`CLAUDE.local.md` next to `CLAUDE.md`), the context goes there
    /// instead, and otherwise the agent starts from the repository's file and its prompt alone.
    ///
    /// Inside a sandbox the file is listed in `.git/info/exclude`, so the delta stays clean (spec §4.6).
    /// Adding a second repository moves the thread cwd from the sandbox up to the task root: the copies
    /// left behind are removed, so the agent can never read a stale one.
    private func writeProjection(_ record: TaskRecord, scopeContext: String?, scopeRepos: [String],
                                 repoSummaries: [RepoContextSummary], contextFiles: [String]) async throws {
        let others = scopeRepos.map(TaskRepo.normalize).filter { $0 != "." }
        let markdown = TaskProjection.agentsMarkdown(task: record, otherRepos: others, scopeName: record.scopeName, scopeContext: scopeContext,
                                                     repoSummaries: repoSummaries)
        let names = Self.contextFileNames(contextFiles)
        let directory = record.threadCwd
        // The thread starts inside a worktree whenever the cwd is a sandbox (always, for a repo scope).
        let sandbox = record.activeRepos.first { $0.sandboxURL.filesystemPath == directory.filesystemPath }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                let file = directory.appending(path: name, directoryHint: .notDirectory)
                let companion = Self.companionContextFile[name].map { directory.appending(path: $0, directoryHint: .notDirectory) }
                guard Self.isRepositoryOwned(file) else {
                    try markdown.write(to: file, atomically: true, encoding: .utf8)
                    if let sandbox { try await excludeFromGit(name, in: sandbox, task: record) }
                    // The repository's own file is gone: a companion left from before would load the context twice.
                    if let companion, Self.isGenerated(companion) { try? FileManager.default.removeItem(at: companion) }
                    continue
                }
                guard let companion, !Self.isRepositoryOwned(companion) else { continue }
                try markdown.write(to: companion, atomically: true, encoding: .utf8)
                if let sandbox { try await excludeFromGit(companion.lastPathComponent, in: sandbox, task: record) }
            }
            try await removeGeneratedContextFiles(names + names.compactMap { Self.companionContextFile[$0] },
                                                  outside: directory, task: record)
            if !record.isMonoRepo {
                try TaskProjection.workspaceJSON(task: record).write(to: record.workspaceURL, options: [.atomic])
            }
        } catch let error as TaskError {
            throw error
        } catch {
            throw TaskError.persistence("projection write failed: \(String(describing: error))")
        }
    }

    /// Files a driver reads *in addition to* a context file, so the task context can sit beside a repository's
    /// own. Only additive ones belong here: a file read instead (Codex's `AGENTS.override.md`) would shadow the
    /// repository's rules.
    static let companionContextFile = ["CLAUDE.md": "CLAUDE.local.md"]

    /// A file that exists and was not written by Scope.
    static func isRepositoryOwned(_ file: URL) -> Bool {
        guard let existing = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return !existing.hasPrefix(TaskProjection.generatedMarker)
    }

    static func isGenerated(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.hasPrefix(TaskProjection.generatedMarker) == true
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
