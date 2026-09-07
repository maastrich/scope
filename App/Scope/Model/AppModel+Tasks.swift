import AppKit
import Foundation
import ScopeCore
import ScopeTasks

/// Task actions (spec §4.3): create, add a repo, archive, close. The worktree work runs inside the
/// `TaskManager` actor, off the main actor; the UI only sees the resulting `TaskState`.
extension AppModel {
    /// Opens the New Task sheet for a scope (⌘⇧T, sidebar footer).
    func presentNewTask(in scopeID: ScopeID? = nil) {
        guard let id = scopeID ?? currentScope?.id, scope(id)?.kind != .missing else { return }
        newTaskScopeID = id
    }

    /// Creates the task, selects it and starts its watcher. Throws `TaskError` for the sheet to show inline.
    @discardableResult
    func createTask(name: String, in scopeID: ScopeID, repos: [String]) async throws -> TaskState {
        guard let scope = scope(scopeID) else { throw TaskError.persistence("scope not found") }
        let scopeRepos = scope.repos.map(\.id)
        let summaries = await graphSummaries(for: scope)
        let record: TaskRecord
        do {
            record = try await env.tasks.create(name: name, in: scope.declaration, repos: repos, scopeRepos: scopeRepos, repoSummaries: summaries)
        } catch {
            problems.error("Could not create task “\(name)”", detail: String(describing: error), scope: scopeID)
            throw error
        }
        let state = TaskState(record: record, git: env.git)
        tasks.append(state)
        state.startWatching()
        state.refresh()
        selection = .task(record.id)
        // The base checkouts gained a worktree: refresh their facts.
        scope.refreshFacts()
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
