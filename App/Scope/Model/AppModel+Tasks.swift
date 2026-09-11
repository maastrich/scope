import AppKit
import Foundation
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks

/// Task actions (spec §4.3): create, add a repo, archive, close. The worktree work runs inside the
/// `TaskManager` actor, off the main actor; the UI only sees the resulting `TaskState`.
extension AppModel {
    /// Opens the New Task sheet for a scope (⌘⇧T, sidebar footer).
    func presentNewTask(in scopeID: ScopeID? = nil) {
        guard let id = scopeID ?? currentScope?.id, scope(id)?.kind != .missing else { return }
        newTaskScopeID = id
    }

    /// Base checkouts of `repos` (relative paths, `"."` for the scope itself) in `scope`.
    private func baseURLs(of repos: [String], in scope: ScopeState) -> [URL] {
        repos.map { path in
            let normalized = TaskRepo.normalize(path)
            return normalized == "." ? scope.url : scope.url.appending(path: normalized, directoryHint: .isDirectory)
        }
    }

    /// The context file names the installed drivers read (`AGENTS.md`, `CLAUDE.md`): a task writes its
    /// projection under each, since its threads can run different drivers. `none` opts a profile out.
    var contextFileNames: [String] {
        drivers.profiles.compactMap { profile in
            guard let context = profile.context, context.mode != .none else { return nil }
            return context.file
        }
    }

    /// Task slugs and sandbox folders already used in a scope (the proposer keeps clear of them).
    private func takenTaskSlugs(in scope: ScopeState) -> Set<String> {
        var taken = Set(tasks(in: scope.id).map(\.record.slug))
        let folder = env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) { taken.formUnion(names) }
        return taken
    }

    /// What a task request turned out to be about: the repositories, and whether it continues work that
    /// already exists instead of opening a branch. Everything in it is shown and editable in the sheet.
    struct TaskRequestResolution: Sendable {
        /// Relative paths of the repositories the request names; empty when nothing was recognised.
        var repos: [String] = []
        var startPoint: TaskStartPoint = .defaultBranch
        /// The pull request the prompt named and `gh` resolved.
        var pullRequest: PullRequest?
        /// A pull request was named but could not be resolved; the reason is worth showing.
        var unresolved: String?
        /// A task of this scope is already bound to that pull request.
        var existingTask: TaskID?
    }

    /// Reads the prompt and works out what it is about, before anything is created.
    ///
    /// A pull request named in the prompt wins: its repository comes from the `origin` remote it names (not
    /// from a folder name — `.../acme-front/pull/6613` lives in the folder `front`), its head becomes the
    /// start point and its number the task's identity. Otherwise repositories and an existing branch are
    /// matched against what the scope already knows. Local and instant except for the one `gh pr view`.
    func resolveTaskRequest(prompt: String, in scopeID: ScopeID, knownBranches: [String] = []) async -> TaskRequestResolution {
        guard let scope = scope(scopeID) else { return TaskRequestResolution() }
        let candidates = repoCandidates(in: scope)

        var resolution = TaskRequestResolution()
        resolution.repos = TaskTargets.repos(namedIn: prompt, among: candidates)

        if let reference = PullRequestReference.detect(in: prompt) {
            return await resolve(reference, in: scope, candidates: candidates, keeping: resolution)
        }

        if let branch = TaskTargets.branch(namedIn: prompt, among: knownBranches) {
            resolution.startPoint = .existingBranch(branch)
        }
        return resolution
    }

    /// The scope's repositories as the New Task sheet sees them (`"."` for a repo scope).
    func repoCandidates(in scope: ScopeState) -> [RepoCandidate] {
        let isRepoScope = scope.kind == .repo || scope.repos.contains { $0.id.isEmpty }
        return isRepoScope
            ? [RepoCandidate(path: ".", name: scope.name, remote: scope.repos.first?.facts?.remote)]
            : scope.repos.map { RepoCandidate(path: $0.id, name: $0.shortName, remote: $0.facts?.remote) }
    }

    /// Turns a reference into a real pull request through `gh`, whether it was read off the prompt or
    /// answered by a microsession: the model names a pull request, `gh pr view` says what it is. The head
    /// that gets checked out never comes from the model's own words.
    func resolve(_ reference: PullRequestReference, in scope: ScopeState, candidates: [RepoCandidate],
                 keeping resolution: TaskRequestResolution) async -> TaskRequestResolution {
        var resolution = resolution
        guard let candidate = TaskTargets.repo(for: reference, among: candidates) else {
            resolution.unresolved = "\(reference.label) is not a pull request of a repository in this scope."
            return resolution
        }
        guard let gh = GhClient.locate() else {
            resolution.unresolved = "\(reference.label): gh is not installed, so its branch cannot be looked up."
            return resolution
        }
        let checkout = baseURLs(of: [candidate.path], in: scope).first ?? scope.url
        do {
            let pr = try await gh.prView(number: reference.number, in: checkout, repo: reference.fullName)
            resolution.repos = [candidate.path]
            resolution.pullRequest = pr
            resolution.startPoint = .pullRequest(pr)
            resolution.existingTask = tasks(in: scope.id).first { $0.record.pullRequest?.number == pr.number }?.id
            resolution.unresolved = nil
        } catch {
            resolution.unresolved = "\(reference.label) could not be read: \(String(describing: error))"
        }
        return resolution
    }

    /// `base`, or `base-2`, `base-3`… when a task or a sandbox folder of the scope already uses it.
    func uniqueTaskSlug(_ base: String, in scopeID: ScopeID) -> String {
        guard let scope = scope(scopeID) else { return base }
        return SlugAllocator.unique(base: base, taken: takenTaskSlugs(in: scope))
    }

    /// Branch-naming evidence of the repos a task would sandbox (New Task sheet, gathered once per prompt).
    func branchEvidence(for repos: [String], in scopeID: ScopeID) async -> BranchEvidence {
        guard let scope = scope(scopeID) else { return BranchEvidence() }
        return await BranchEvidence.gather(repos: baseURLs(of: repos, in: scope), registry: env.git)
    }

    /// Level 0: title / slug / branch derived from the prompt and the evidence, instantly.
    func fallbackProposal(prompt: String, evidence: BranchEvidence, in scopeID: ScopeID) -> TaskProposal {
        let taken = scope(scopeID).map(takenTaskSlugs) ?? []
        return TaskProposer.fallback(prompt: prompt, evidence: evidence, takenSlugs: taken)
    }

    /// Level 1: asks `driverID` (headless) for a branch that follows the repo's convention; falls back to
    /// `fallbackProposal` when the driver cannot answer (see `TaskProposal.source`).
    func proposeTask(prompt: String, driverID: String?, repos: [String], evidence: BranchEvidence, in scopeID: ScopeID) async -> TaskProposal {
        guard let scope = scope(scopeID) else { return TaskProposer.fallback(prompt: prompt, evidence: evidence, takenSlugs: []) }
        let profile = profile(id: driverID)
        let bases = baseURLs(of: repos, in: scope)
        let cwd = bases.first ?? scope.url
        let shell = await env.shell.environment()
        let validator = TaskProposer.gitRefValidator(client: await env.git.client(for: cwd))
        // A light run with tools may spend a while in `gh`; a plain headless one keeps the short bound.
        let timeout = profile?.headlessLight?.isEmpty == false ? TaskProposer.microsessionTimeout : TaskProposer.defaultTimeout
        let proposer = TaskProposer(
            profile: profile, runner: SubprocessHeadlessRunner(path: shell.path, shell: shell.shell), home: env.home,
            timeout: timeout, validateRef: validator
        )
        let taken = takenTaskSlugs(in: scope)
        // `propose` is nonisolated async: it runs off the main actor, and cancelling the caller's task kills the driver.
        return await proposer.propose(prompt: prompt, evidence: evidence, cwd: cwd, scopeRoot: scope.url,
                                      takenSlugs: taken, candidates: repoCandidates(in: scope))
    }

    /// A pull request a microsession found in a request that named none literally: resolved through `gh`,
    /// exactly as a pasted URL would be. Nil when it resolves to nothing usable, so the caller keeps the
    /// new-branch proposal it already has.
    func resolveProposedPullRequest(_ reference: PullRequestReference, in scopeID: ScopeID) async -> TaskRequestResolution? {
        guard let scope = scope(scopeID) else { return nil }
        let resolved = await resolve(reference, in: scope, candidates: repoCandidates(in: scope), keeping: TaskRequestResolution())
        return resolved.pullRequest == nil ? nil : resolved
    }

    /// Creates the task from a proposal, selects it, starts its watcher, then opens its first thread with
    /// `driverID` and the prompt as the driver's opening request. Throws `TaskError` for the sheet to show inline.
    @discardableResult
    ///
    /// The sandboxes are then prepared in the background (`startSetup`): `runSetup` runs the setup commands, the
    /// `.env*` files are copied either way, and the first thread waits for it before it launches.
    func createTask(
        _ proposal: TaskProposal, prompt: String, driverID: String?, in scopeID: ScopeID, repos: [String],
        startPoint: TaskStartPoint = .defaultBranch, openThread: Bool = true, runSetup: Bool = true,
        threadOrigin: ThreadOrigin = .user, createdBy: String? = nil
    ) async throws -> TaskState {
        guard let scope = scope(scopeID) else { throw TaskError.persistence("scope not found") }
        let scopeRepos = scope.repos.map(\.id)
        let summaries = await graphSummaries(for: scope)
        let record: TaskRecord
        do {
            record = try await env.tasks.create(
                name: proposal.title, branch: proposal.branch, slug: proposal.slug, initialPrompt: prompt,
                in: scope.declaration, repos: repos, startPoint: startPoint,
                pullRequest: startPoint.pullRequest.map(LinkedPullRequest.init),
                scopeRepos: scopeRepos, repoSummaries: summaries, contextFiles: contextFileNames,
                createdBy: createdBy
            )
        } catch {
            problems.error("Could not create task “\(proposal.title)”", detail: String(describing: error), scope: scopeID)
            throw error
        }
        let state = TaskState(record: record, git: env.git)
        tasks.append(state)
        state.startWatching()
        state.refresh()
        startSetup(for: state, runCommands: runSetup)
        selection = .task(record.id)
        // The base checkouts gained a worktree: refresh their facts.
        scope.refreshFacts()
        guard openThread else { return state }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        await newThread(in: scopeID, driverID: driverID, taskID: record.id,
                        initialPrompt: trimmed.isEmpty ? nil : trimmed, origin: threadOrigin)
        return state
    }

    /// Adds a base repo of the scope to a running task (context menu *Add repo…*).
    func addRepo(_ relativePath: String, to taskID: TaskID) async {
        guard let task = task(taskID), let scope = scope(task.scopeID) else { return }
        do {
            let summaries = await graphSummaries(for: scope)
            let record = try await env.tasks.addRepo(taskID, repo: relativePath, scopeRepos: scope.repos.map(\.id),
                                                     repoSummaries: summaries, contextFiles: contextFileNames)
            task.update(record: record)
            task.stopWatching()
            task.startWatching()
            startSetup(for: task, runCommands: true, only: [relativePath])
        } catch {
            problems.error("Could not add \(relativePath) to \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    // MARK: Setup and teardown

    /// The setup / teardown commands and the copied files of each repository of a task: its graph card, with the
    /// scope's config (`repoCommands` in `config.json`) over it.
    func sandboxCommands(for record: TaskRecord) async -> [String: SandboxCommands] {
        guard let scope = scope(record.scopeID) else { return [:] }
        let cards = Dictionary(await graphSummaries(for: scope).map { (TaskRepo.normalize($0.path), $0) },
                               uniquingKeysWith: { first, _ in first })
        var commands: [String: SandboxCommands] = [:]
        for repo in record.repos {
            let override = scope.declaration.commandOverride(for: repo.repoRelativePath)
            commands[repo.repoRelativePath] = SandboxCommands.resolve(
                card: cards[repo.repoRelativePath], setupOverride: override?.setup,
                teardownOverride: override?.teardown, copyFilesOverride: override?.copyFiles
            )
        }
        return commands
    }

    /// Commands run in the login-shell environment the threads get, resolved once per app run.
    private func commandRunner() async -> ShellCommandRunner {
        let shell = await env.shell.environment()
        return ShellCommandRunner(shell: shell.shell, baseEnvironment: shell.variables)
    }

    /// Prepares a task's sandboxes in the background (`TaskManager.runSetup`). Its threads wait for this before
    /// they launch; a setup asked for while another runs goes after it.
    func startSetup(for task: TaskState, runCommands: Bool, only: [String]? = nil) {
        let id = task.id
        let token = UUID()
        let previous = setupRuns[id]?.run
        let run = Task { [weak self] in
            await previous?.value
            await self?.performSetup(task, runCommands: runCommands, only: only)
            if self?.setupRuns[id]?.token == token { self?.setupRuns[id] = nil }
        }
        setupRuns[id] = (token, run)
    }

    private func performSetup(_ task: TaskState, runCommands: Bool, only: [String]?) async {
        let commands = await sandboxCommands(for: task.record)
        let runner = await commandRunner()
        do {
            let record = try await env.tasks.runSetup(task.id, commands: commands, runCommands: runCommands,
                                                      runner: runner, only: only) { record in
                await MainActor.run { task.update(record: record) }
            }
            guard record.setupState == .failed else { return }
            problems.error("The setup of \(task.name) failed", detail: SetupLog.tail(record.setup?.log ?? "", lines: 60),
                           scope: task.scopeID,
                           actions: [ProblemAction(title: "Run Setup Again", kind: .rerunTaskSetup(task.id.rawValue)),
                                     .reveal(record.threadCwd.path, title: "Reveal Sandbox")])
        } catch {
            // Closed or archived mid-setup: nothing left to report on.
            guard !Task.isCancelled, self.task(task.id) != nil else { return }
            problems.error("Could not run the setup of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// A setup still running when its task goes: its commands are killed rather than left writing into a folder
    /// about to be removed.
    private func cancelSetup(_ taskID: TaskID) {
        setupRuns[taskID]?.run.cancel()
        setupRuns[taskID] = nil
    }

    private func teardown(for task: TaskState) async -> TaskManager.Teardown {
        TaskManager.Teardown(commands: await sandboxCommands(for: task.record), runner: await commandRunner())
    }

    private func reportTeardownFailure(_ task: TaskState, repo: String, summary: String, log: String) {
        problems.error("The teardown of \(task.name) failed; its sandboxes were kept",
                       detail: "\(repo): \(summary)\n\n\(SetupLog.tail(log, lines: 60))", scope: task.scopeID,
                       actions: [.reveal(task.record.threadCwd.path, title: "Reveal Sandbox")])
    }

    /// What `TaskStatus.resolve` decides from: the task's threads, its delta, its setup and its pull request.
    func taskFacts(for task: TaskState) -> TaskFacts {
        let pullRequest = task.record.pullRequest.map { link in
            let live = livePullRequest(for: task)
            return PullRequestFacts(number: link.number, isDraft: live?.isDraft ?? false,
                                    checks: live?.checks ?? .none, mergeable: live?.mergeable ?? .unknown)
        }
        return TaskFacts(threads: threads(in: task.id).map(\.displayState), additions: task.totalAdditions,
                         deletions: task.totalDeletions, isDirty: task.dirtyRepoCount > 0, setup: task.record.setupState,
                         pullRequest: pullRequest)
    }

    /// Repos of the task's scope that are not part of the task yet.
    func candidateRepos(for task: TaskState) -> [RepoState] {
        guard let scope = scope(task.scopeID) else { return [] }
        if task.record.isMonoRepo { return [] }
        let taken = Set(task.record.repos.map(\.repoRelativePath))
        return scope.repos.filter { !taken.contains($0.id) && !$0.id.isEmpty }
    }

    /// Removes the worktrees, keeps the branches and the record. Refused with uncommitted changes unless forced.
    /// The teardown commands run first; when one fails nothing is removed, unless the user says to go on without.
    func archiveTask(_ taskID: TaskID, force: Bool = false, skipTeardown: Bool = false) async {
        guard let task = task(taskID) else { return }
        cancelSetup(taskID)
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
        do {
            let record = try await env.tasks.archive(taskID, force: force, teardown: skipTeardown ? nil : await teardown(for: task))
            task.stopWatching()
            task.update(record: record)
            if selection == .task(taskID) { selection = .scope(task.scopeID) }
            scope(task.scopeID)?.refreshFacts()
        } catch TaskError.uncommittedChanges(let repo) where !force {
            if await confirmForce(title: "Archive “\(task.name)” anyway?",
                                  detail: "The sandbox of \(repo) has uncommitted changes; archiving discards them.",
                                  button: "Archive") {
                await archiveTask(taskID, force: true, skipTeardown: skipTeardown)
            }
        } catch TaskError.teardownFailed(let repo, let summary, let log) {
            reportTeardownFailure(task, repo: repo, summary: summary, log: log)
            if await confirmForce(title: "Archive “\(task.name)” without its teardown?",
                                  detail: "The teardown command of \(repo) failed (\(summary)); what it was meant to stop may still be running.",
                                  button: "Archive Anyway") {
                await archiveTask(taskID, force: force, skipTeardown: true)
            }
        } catch {
            problems.error("Could not archive \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// Closes the task for good: threads closed, worktrees removed, record deleted. Confirmation first;
    /// `TaskError.uncommittedChanges` / `.branchNotMerged` come back as a second alert offering Force.
    func closeTask(_ taskID: TaskID, deleteBranch: Bool, force: Bool = false, confirmed: Bool = false,
                   skipTeardown: Bool = false) async {
        guard let task = task(taskID) else { return }
        if !confirmed {
            let running = threads(in: taskID).filter(\.isAlive).count
            var detail = "The sandboxes under \(task.record.root) are removed"
            detail += deleteBranch ? " and the branch \(task.branch) is deleted." : "; the branch \(task.branch) is kept."
            if running > 0 { detail += "\n\n\(running) running \(running == 1 ? "thread" : "threads") will be hung up." }
            guard await confirmForce(title: "Close “\(task.name)”?", detail: detail, button: "Close Task") else { return }
        }
        cancelSetup(taskID)
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
        do {
            try await env.tasks.close(taskID, deleteBranch: deleteBranch, force: force,
                                      teardown: skipTeardown ? nil : await teardown(for: task))
        } catch TaskError.uncommittedChanges(let repo) where !force {
            if await confirmForce(title: "Close “\(task.name)” anyway?",
                                  detail: "The sandbox of \(repo) has uncommitted changes; closing discards them.",
                                  button: "Force Close") {
                await closeTask(taskID, deleteBranch: deleteBranch, force: true, confirmed: true, skipTeardown: skipTeardown)
            }
            return
        } catch TaskError.branchNotMerged(let repo, let branch) where !force {
            if await confirmForce(title: "Delete unmerged branch \(branch)?",
                                  detail: "\(repo): the branch is not merged; its commits will be lost.",
                                  button: "Delete Branch") {
                await closeTask(taskID, deleteBranch: deleteBranch, force: true, confirmed: true, skipTeardown: true)
            }
            return
        } catch TaskError.teardownFailed(let repo, let summary, let log) {
            reportTeardownFailure(task, repo: repo, summary: summary, log: log)
            if await confirmForce(title: "Close “\(task.name)” without its teardown?",
                                  detail: "The teardown command of \(repo) failed (\(summary)); what it was meant to stop may still be running.",
                                  button: "Close Anyway") {
                await closeTask(taskID, deleteBranch: deleteBranch, force: force, confirmed: true, skipTeardown: true)
            }
            return
        } catch {
            problems.error("Could not close \(task.name)", detail: String(describing: error), scope: task.scopeID)
            return
        }
        forgetClosedTask(task)
    }

    /// Closes a task without asking anything — the control socket's path: its threads hung up, its sandboxes
    /// removed, its branch deleted when asked. Throws `TaskError` (uncommitted changes, unmerged branch) where
    /// `closeTask` would put up a dialog; `force` goes through both, losing that work.
    func removeTask(_ taskID: TaskID, deleteBranch: Bool, force: Bool) async throws {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        // Refuse before hanging up anything: the sandbox check below would come too late for the threads.
        if !force, task.dirtyRepoCount > 0 {
            throw TaskError.uncommittedChanges(repo: task.record.slug)
        }
        cancelSetup(taskID)
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
        do {
            try await env.tasks.close(taskID, deleteBranch: deleteBranch, force: force, teardown: await teardown(for: task))
        } catch TaskError.teardownFailed(let repo, let summary, let log) {
            reportTeardownFailure(task, repo: repo, summary: summary, log: log)
            throw TaskError.teardownFailed(repo: repo, summary: summary, log: log)
        }
        forgetClosedTask(task)
    }

    /// What is left to do once the task manager has removed a task.
    private func forgetClosedTask(_ task: TaskState) {
        let taskID = task.id
        task.stopWatching()
        let reviews = review.store
        Task { await reviews.delete(taskID) }
        tasks.removeAll { $0.id == taskID }
        if selection == .task(taskID) || currentTask?.id == taskID {
            selection = .scope(task.scopeID)
        }
        scope(task.scopeID)?.refreshFacts()
    }

    func confirmForce(title: String, detail: String, button: String, destructive: Bool = true) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}
