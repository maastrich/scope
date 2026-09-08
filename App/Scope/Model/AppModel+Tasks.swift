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

    /// Task slugs and sandbox folders already used in a scope (the proposer keeps clear of them).
    private func takenTaskSlugs(in scope: ScopeState) -> Set<String> {
        var taken = Set(tasks(in: scope.id).map(\.record.slug))
        let folder = env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) { taken.formUnion(names) }
        return taken
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
        let proposer = TaskProposer(
            profile: profile, runner: SubprocessHeadlessRunner(path: shell.path, shell: shell.shell), home: env.home, validateRef: validator
        )
        let taken = takenTaskSlugs(in: scope)
        // `propose` is nonisolated async: it runs off the main actor, and cancelling the caller's task kills the driver.
        return await proposer.propose(prompt: prompt, evidence: evidence, cwd: cwd, scopeRoot: scope.url, takenSlugs: taken)
    }

    /// Creates the task from a proposal, selects it, starts its watcher, then opens its first thread with
    /// `driverID` and the prompt as the driver's opening request. Throws `TaskError` for the sheet to show inline.
    @discardableResult
    func createTask(_ proposal: TaskProposal, prompt: String, driverID: String?, in scopeID: ScopeID, repos: [String]) async throws -> TaskState {
        guard let scope = scope(scopeID) else { throw TaskError.persistence("scope not found") }
        let scopeRepos = scope.repos.map(\.id)
        let summaries = await graphSummaries(for: scope)
        let record: TaskRecord
        do {
            record = try await env.tasks.create(
                name: proposal.title, branch: proposal.branch, slug: proposal.slug, initialPrompt: prompt,
                in: scope.declaration, repos: repos, scopeRepos: scopeRepos, repoSummaries: summaries
            )
        } catch {
            problems.error("Could not create task “\(proposal.title)”", detail: String(describing: error), scope: scopeID)
            throw error
        }
        let state = TaskState(record: record, git: env.git)
        tasks.append(state)
        state.startWatching()
        state.refresh()
        selection = .task(record.id)
        // The base checkouts gained a worktree: refresh their facts.
        scope.refreshFacts()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        await newThread(in: scopeID, driverID: driverID, taskID: record.id, initialPrompt: trimmed.isEmpty ? nil : trimmed)
        return state
    }

    /// Adds a base repo of the scope to a running task (context menu *Add repo…*).
    func addRepo(_ relativePath: String, to taskID: TaskID) async {
        guard let task = task(taskID), let scope = scope(task.scopeID) else { return }
        do {
            let summaries = await graphSummaries(for: scope)
            let record = try await env.tasks.addRepo(taskID, repo: relativePath, scopeRepos: scope.repos.map(\.id), repoSummaries: summaries)
            task.update(record: record)
            task.stopWatching()
            task.startWatching()
        } catch {
            problems.error("Could not add \(relativePath) to \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// Repos of the task's scope that are not part of the task yet.
    func candidateRepos(for task: TaskState) -> [RepoState] {
        guard let scope = scope(task.scopeID) else { return [] }
        if task.record.isMonoRepo { return [] }
        let taken = Set(task.record.repos.map(\.repoRelativePath))
        return scope.repos.filter { !taken.contains($0.id) && !$0.id.isEmpty }
    }

    /// Removes the worktrees, keeps the branches and the record. Refused with uncommitted changes unless forced.
    func archiveTask(_ taskID: TaskID, force: Bool = false) async {
        guard let task = task(taskID) else { return }
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
        do {
            let record = try await env.tasks.archive(taskID, force: force)
            task.stopWatching()
            task.update(record: record)
            if selection == .task(taskID) { selection = .scope(task.scopeID) }
            scope(task.scopeID)?.refreshFacts()
        } catch TaskError.uncommittedChanges(let repo) where !force {
            if await confirmForce(title: "Archive “\(task.name)” anyway?",
                                  detail: "The sandbox of \(repo) has uncommitted changes; archiving discards them.",
                                  button: "Archive") {
                await archiveTask(taskID, force: true)
            }
        } catch {
            problems.error("Could not archive \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// Closes the task for good: threads closed, worktrees removed, record deleted. Confirmation first;
    /// `TaskError.uncommittedChanges` / `.branchNotMerged` come back as a second alert offering Force.
    func closeTask(_ taskID: TaskID, deleteBranch: Bool, force: Bool = false, confirmed: Bool = false) async {
        guard let task = task(taskID) else { return }
        if !confirmed {
            let running = threads(in: taskID).filter(\.isAlive).count
            var detail = "The sandboxes under \(task.record.root) are removed"
            detail += deleteBranch ? " and the branch \(task.branch) is deleted." : "; the branch \(task.branch) is kept."
            if running > 0 { detail += "\n\n\(running) running \(running == 1 ? "thread" : "threads") will be hung up." }
            guard await confirmForce(title: "Close “\(task.name)”?", detail: detail, button: "Close Task") else { return }
        }
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
        do {
            try await env.tasks.close(taskID, deleteBranch: deleteBranch, force: force)
        } catch TaskError.uncommittedChanges(let repo) where !force {
            if await confirmForce(title: "Close “\(task.name)” anyway?",
                                  detail: "The sandbox of \(repo) has uncommitted changes; closing discards them.",
                                  button: "Force Close") {
                await closeTask(taskID, deleteBranch: deleteBranch, force: true, confirmed: true)
            }
            return
        } catch TaskError.branchNotMerged(let repo, let branch) where !force {
            if await confirmForce(title: "Delete unmerged branch \(branch)?",
                                  detail: "\(repo): the branch is not merged; its commits will be lost.",
                                  button: "Delete Branch") {
                await closeTask(taskID, deleteBranch: deleteBranch, force: true, confirmed: true)
            }
            return
        } catch {
            problems.error("Could not close \(task.name)", detail: String(describing: error), scope: task.scopeID)
            return
        }
        task.stopWatching()
        tasks.removeAll { $0.id == taskID }
        if selection == .task(taskID) || currentTask?.id == taskID {
            selection = .scope(task.scopeID)
        }
        scope(task.scopeID)?.refreshFacts()
    }

    private func confirmForce(title: String, detail: String, button: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button).hasDestructiveAction = true
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
