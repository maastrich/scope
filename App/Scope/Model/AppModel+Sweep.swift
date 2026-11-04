import AppKit
import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Taking out of a task what it gained (a repository, a worktree, a pull request, the issue, the topic, a milestone),
/// one at a time or all at once with a sweep (`TaskSweepPlan`). The inspector, the palette, `scope task remove` /
/// `scope task sweep` and the MCP tools all land here. Nothing reaches GitHub unless the user ticked it, and nothing
/// outside Scope's home, the sandboxes and their worktrees is ever touched.
extension AppModel {
    /// What a context file rewrite needs from the task's scope.
    private struct Projection {
        var context: String?
        var repos: [String]
        var summaries: [RepoContextSummary]
    }

    private func projection(for task: TaskState) async -> Projection {
        guard let scope = scope(task.scopeID) else { return Projection(context: nil, repos: [], summaries: []) }
        return Projection(context: scope.declaration.context, repos: scope.repos.map(\.id), summaries: await graphSummaries(for: scope))
    }

    /// Hangs up the threads whose working directory lies in one of `folders` (worktrees about to go). Reopenable for
    /// the undo window like any close.
    private func closeThreads(of task: TaskState, inside folders: [String], except caller: ThreadID? = nil) async {
        let folders = folders.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for session in threads(in: task.id) where session.id != caller {
            let cwd = URL(fileURLWithPath: session.record.cwd).standardizedFileURL.path
            guard folders.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }
            await close(session.id, force: true)
        }
    }

    /// The task's rows, watchers and counts after its repositories or worktrees changed.
    private func refreshAfterRemoval(_ task: TaskState, record: TaskRecord, reposChanged: Bool) async {
        task.update(record: record)
        if reposChanged {
            task.stopWatching()
            task.startWatching()
        }
        if currentTask?.id == task.id { await delta.load(task: task) }
        refreshDiskUsage(of: task)
        scope(task.scopeID)?.refreshFacts()
    }

    func journalRemove(_ element: String, task: TaskState, outcome: String, by requester: CloseRequester) {
        Journal.record(JournalEvent(kind: .taskRemove, name: element, outcome: outcome, scope: scope(task.scopeID)?.declaration.slug,
                                    task: task.id.rawValue, source: requester.isAgent ? "agent" : "user"))
    }

    // MARK: One at a time

    /// A repository out of the task (`TaskManager.removeRepo`): its threads hung up, its worktrees saved and removed,
    /// its branch kept. The notices say where the unfinished work went.
    @discardableResult
    func removeRepo(_ path: String, from taskID: TaskID, by requester: CloseRequester = .user,
                    except caller: ThreadID? = nil) async throws -> [DismantleNotice] {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let normalized = TaskRepo.normalize(path)
        guard let repo = task.record.repo(at: normalized) else { throw TaskError.repoNotFound(repo: normalized) }
        _ = try TaskSweep.removingRepo(normalized, from: task.record)
        await closeThreads(of: task, inside: repo.sandboxes.map(\.sandboxPath), except: caller)
        let inputs = await projection(for: task)
        do {
            let (record, notices) = try await env.tasks.removeRepo(taskID, repo: normalized, scopeContext: inputs.context, scopeRepos: inputs.repos,
                                                                   repoSummaries: inputs.summaries, contextFiles: contextFileNames)
            for link in task.record.pullRequests where !record.pullRequests.contains(where: { $0.url == link.url }) {
                pullRequests.forgetTaskPullRequest(link.url, for: taskID)
            }
            await refreshAfterRemoval(task, record: record, reposChanged: true)
            journalRemove("repo", task: task, outcome: "ok", by: requester)
            reportSaved(notices, task: task, what: TaskRepo.displayName(normalized))
            return notices
        } catch {
            journalRemove("repo", task: task, outcome: "failed", by: requester)
            throw error
        }
    }

    /// Scope forgets a pull request: out of the task and its panel, ignored by the next discoveries. Not closed.
    func forgetPullRequest(_ url: URL, of taskID: TaskID, by requester: CloseRequester = .user) async throws {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let record = try await env.tasks.forgetPullRequest(taskID, url: url)
        pullRequests.forgetTaskPullRequest(url, for: taskID)
        if selectedPullRequest(for: task)?.url == url, let first = record.pullRequests.first { selectPullRequest(first, for: task) }
        task.update(record: record)
        journalRemove("pull-request", task: task, outcome: "ok", by: requester)
    }

    func unlinkIssue(of taskID: TaskID, by requester: CloseRequester = .user) async throws {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let record = try await env.tasks.unlinkIssue(taskID)
        task.update(record: record)
        await regenerateContextFile(of: task)
        journalRemove("issue", task: task, outcome: "ok", by: requester)
    }

    func removeMilestone(_ reference: String, of mission: TaskState, by requester: CloseRequester = .user) async throws -> Milestone {
        let (record, removed) = try await env.tasks.removeMilestone(mission.id, milestone: reference)
        mission.update(record: record)
        await regenerateContextFile(of: mission)
        journalRemove("milestone", task: mission, outcome: "ok", by: requester)
        return removed
    }

    /// The topic, as *Remove from Topic* takes it: the task alone, filed nowhere, never re-filed on its own.
    func removeTopic(of taskID: TaskID, by requester: CloseRequester = .user) async {
        guard let task = task(taskID) else { return }
        await setTopic(nil, for: [taskID])
        journalRemove("topic", task: task, outcome: "ok", by: requester)
    }

    private func reportSaved(_ notices: [DismantleNotice], task: TaskState, what: String) {
        let saved = notices.compactMap { notice -> String? in
            guard case .changesSaved(let repo, let ref, let skipped) = notice else { return nil }
            return "\(repo): uncommitted changes → \(ref)" + (skipped.isEmpty ? "" : " (too big to keep, deleted: \(skipped.joined(separator: ", ")))")
        }
        guard !saved.isEmpty else { return }
        problems.report(Problem(severity: .info, title: "\(task.name): unfinished work in \(what) saved",
                                detail: saved.joined(separator: "\n"), scopeID: task.scopeID))
    }

    // MARK: From the inspector and the palette

    func removeRepoFromUI(_ repo: TaskRepo, of task: TaskState) {
        Usage.click("task.remove-repo", label: "Remove a repository from the task")
        Task {
            let name = repo.isScopeRoot ? task.record.scopeName : repo.repoRelativePath
            guard await confirmForce(title: "Remove \(name) from “\(task.name)”?",
                                     detail: "Its worktrees go to the trash, their uncommitted changes saved first under refs/scope/salvage/. "
                                         + "The branch stays in your repository; your checkout is not touched.",
                                     button: "Remove") else { return }
            do { try await removeRepo(repo.repoRelativePath, from: task.id) } catch {
                problems.error("Could not remove \(name) from \(task.name)", error: error, scope: task.scopeID, toast: true)
            }
        }
    }

    func forgetPullRequestFromUI(_ link: LinkedPullRequest, of task: TaskState) {
        Usage.click("task.forget-pr", label: "Forget a pull request")
        Task {
            do { try await forgetPullRequest(link.url, of: task.id) } catch {
                problems.error("Could not forget \(link.label)", error: error, scope: task.scopeID)
            }
        }
    }

    func unlinkIssueFromUI(_ task: TaskState) {
        Usage.click("task.unlink-issue", label: "Unlink the task's issue")
        Task {
            do { try await unlinkIssue(of: task.id) } catch {
                problems.error("Could not unlink the issue of \(task.name)", error: error, scope: task.scopeID)
            }
        }
    }

    func removeMilestoneFromUI(_ milestone: Milestone, of mission: TaskState) {
        Usage.click("task.remove-milestone", label: "Remove a milestone")
        Task {
            do { _ = try await removeMilestone(milestone.id, of: mission) } catch {
                problems.error("Could not remove the milestone", error: error, scope: mission.scopeID)
            }
        }
    }

    // MARK: Sweep

    /// The threads of the task in the middle of a turn: what the confirmation says it will interrupt.
    func runningThreads(of taskID: TaskID) -> [ThreadSession] {
        threads(in: taskID).filter { $0.isAlive && ($0.activity.inTurn || $0.isWorking) }
    }

    /// What a sweep did, for the answer and the notice.
    struct SweepResult {
        var outcome: TaskManager.SweepOutcome
        var notes: [String]
        var interrupted: Int
    }

    /// The sweep itself (`TaskManager.sweepTask`), shared by the confirmation and `task.sweep`: running turns
    /// interrupted (never `caller`'s own, which is waiting for this answer), a checkpoint taken, the threads inside
    /// worktrees that go hung up, then the sweep; with `closePullRequests` the open ones closed with `gh`. The undo
    /// is offered like an archive's.
    func sweepTask(_ taskID: TaskID, options: TaskSweepOptions, by requester: CloseRequester = .user,
                   except caller: ThreadID? = nil) async throws -> SweepResult {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let started = ContinuousClock.now
        let plan = try await env.tasks.planSweep(taskID, options: options)
        if let blocked = plan.blocked {
            journalSweep("sweep", task: task, outcome: "refused", since: started, options: options)
            throw TaskError.invalidRepoSelection(blocked)
        }
        var interrupted = 0
        for session in runningThreads(of: taskID) where session.id != caller {
            if session.interruptForSweep() { interrupted += 1 }
        }
        let checkpoint: Int?
        do {
            let taken = try await env.tasks.checkpoints.snapshot(task.record, turn: nil, reason: .beforeSweep)?.number
            if let taken { checkpoint = taken } else { checkpoint = await env.tasks.checkpoints.list(taskID).last?.number }
        } catch {
            journalSweep("sweep", task: task, outcome: "failed", since: started, options: options)
            throw error
        }
        await closeThreads(of: task, inside: plan.removed.map(\.path), except: caller)
        let inputs = await projection(for: task)
        let outcome: TaskManager.SweepOutcome
        do {
            outcome = try await env.tasks.sweepTask(taskID, options: options, checkpoint: checkpoint, scopeContext: inputs.context,
                                                    scopeRepos: inputs.repos, repoSummaries: inputs.summaries, contextFiles: contextFileNames)
        } catch {
            journalSweep("sweep", task: task, outcome: "failed", since: started, options: options)
            throw error
        }
        var notes = outcome.notes
        if options.closePullRequests {
            for link in plan.pullRequests where link.isOpen {
                notes.append(await closeOnGitHub(link, of: task))
            }
        }
        for link in plan.pullRequests { pullRequests.forgetTaskPullRequest(link.url, for: taskID) }
        await refreshAfterRemoval(task, record: outcome.record, reposChanged: !plan.removed.isEmpty)
        await reloadCheckpoints(of: taskID)
        journalSweep("sweep", task: task, outcome: "ok", since: started, options: options,
                     count: plan.removed.count + plan.reset.count)
        remember(.sweptTask(id: taskID, name: task.name, scope: task.scopeID), by: requester)
        return SweepResult(outcome: outcome, notes: notes, interrupted: interrupted)
    }

    /// The last sweep taken back (`TaskManager.undoSweep`). Pull requests closed or branches deleted on GitHub stay so.
    @discardableResult
    func undoSweep(_ taskID: TaskID, by requester: CloseRequester = .user) async throws -> [String] {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        forgetUndo(id: UndoableAction.sweptTask(id: taskID, name: "", scope: task.scopeID).id)
        let started = ContinuousClock.now
        let inputs = await projection(for: task)
        do {
            let (record, notes) = try await env.tasks.undoSweep(taskID, scopeContext: inputs.context, scopeRepos: inputs.repos,
                                                                repoSummaries: inputs.summaries, contextFiles: contextFileNames)
            await refreshAfterRemoval(task, record: record, reposChanged: true)
            journalSweep("undo", task: task, outcome: "ok", since: started, options: nil, count: record.activeSandboxes.count)
            Task { await refreshTaskPullRequest(task) }
            return notes
        } catch {
            journalSweep("undo", task: task, outcome: "failed", since: started, options: nil)
            throw error
        }
    }

    /// The undo toast's button and ⌘Z.
    func undoSweepFromUndo(_ taskID: TaskID) async {
        guard let task = task(taskID) else { return }
        do {
            let notes = try await undoSweep(taskID)
            problems.report(Problem(severity: .info, title: "Sweep of \(task.name) undone",
                                    detail: (["Worktrees, branches, changes and pull requests are back."] + notes).joined(separator: "\n"),
                                    scopeID: task.scopeID))
        } catch {
            problems.error("Could not undo the sweep of \(task.name)", error: error, scope: task.scopeID, toast: true)
        }
    }

    private func journalSweep(_ name: String, task: TaskState, outcome: String, since: ContinuousClock.Instant,
                              options: TaskSweepOptions?, count: Int? = nil) {
        let (whole, atto) = (ContinuousClock.now - since).components
        Journal.record(JournalEvent(kind: .taskSweep, name: name, outcome: outcome, cause: options?.touchesGitHub == true ? "github" : nil,
                                    scope: scope(task.scopeID)?.declaration.slug, task: task.id.rawValue,
                                    seconds: Double(whole) + Double(atto) / 1e18, count: count))
    }

    /// *Sweep Task…* (context menu, inspector, palette): the confirmation lists exactly what goes — pull requests,
    /// worktrees, branches, unpushed commits, modified files, the turns it interrupts — with *Reset the branches on the
    /// base* ticked and the two GitHub boxes unticked.
    func sweepFromUI(_ task: TaskState) {
        Usage.click("task.sweep", label: "Sweep the task")
        Task {
            let plan: TaskSweepPlan
            do { plan = try await env.tasks.planSweep(task.id) } catch {
                problems.error("Could not read what sweeping \(task.name) would do", error: error, scope: task.scopeID)
                return
            }
            if let blocked = plan.blocked {
                problems.error("Cannot sweep \(task.name)", detail: blocked, cause: .busy, scope: task.scopeID, toast: true)
                return
            }
            let running = runningThreads(of: task.id)
            guard let options = confirmSweep(task, plan: plan, running: running) else { return }
            do {
                let result = try await sweepTask(task.id, options: options)
                if !result.notes.isEmpty {
                    problems.report(Problem(severity: .info, title: "\(task.name) swept", detail: result.notes.joined(separator: "\n"),
                                            scopeID: task.scopeID))
                }
            } catch {
                problems.error("Could not sweep \(task.name)", error: error, scope: task.scopeID, toast: true)
            }
        }
    }

    /// The confirmation: `nil` when cancelled, else the boxes as the user left them. The list follows the boxes, so it
    /// always says exactly what the button would do.
    private func confirmSweep(_ task: TaskState, plan: TaskSweepPlan, running: [ThreadSession]) -> TaskSweepOptions? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sweep “\(task.name)”?"
        let interrupted = running.isEmpty ? nil
            : "Interrupted: " + running.map { "“\(displayTitle(for: $0))”" }.joined(separator: ", ") + " (the threads stay)"
        let list = NSTextField(wrappingLabelWithString: "")
        list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        list.preferredMaxLayoutWidth = 380
        let reset = NSButton(checkboxWithTitle: "Reset the branches on the base (local changes discarded)", target: nil, action: nil)
        reset.state = .on
        let close = NSButton(checkboxWithTitle: "Also close the pull requests on GitHub", target: nil, action: nil)
        close.state = .off
        close.isEnabled = plan.pullRequests.contains(where: \.isOpen)
        let remote = NSButton(checkboxWithTitle: "Also delete the remote branches", target: nil, action: nil)
        remote.state = .off
        let record = task.record
        let facts = Dictionary(plan.sandboxes.map { ($0.key, SandboxFacts(unpushedCommits: $0.unpushedCommits, changedFiles: $0.changedFiles)) },
                               uniquingKeysWith: { first, _ in first })
        let follower = SweepConfirmationFollower { [weak alert] in
            let options = TaskSweepOptions(resetBranches: reset.state == .on, closePullRequests: close.state == .on,
                                           deleteRemoteBranches: remote.state == .on)
            let current = TaskSweepPlan.make(record, facts: facts, options: options)
            var lines = current.lines(scopeName: record.scopeName)
            if lines.isEmpty { lines = ["Nothing to sweep: no pull request, no worktree to remove or reset."] }
            if let interrupted { lines.append(interrupted) }
            list.stringValue = lines.map { "• " + $0 }.joined(separator: "\n")
            var summary = "Back to a fresh state. Everything is saved first (a checkpoint and refs/scope/salvage/): Undo takes it all back."
            if current.unpushedCommits > 0 || current.changedFiles > 0 {
                summary += " At stake: \(current.unpushedCommits) unpushed \(current.unpushedCommits == 1 ? "commit" : "commits"), "
                    + "\(current.changedFiles) modified \(current.changedFiles == 1 ? "file" : "files")."
            }
            if options.touchesGitHub { summary += " GitHub is told, and that part cannot be undone." }
            alert?.informativeText = summary
        }
        for box in [reset, close, remote] {
            box.target = follower
            box.action = #selector(SweepConfirmationFollower.changed(_:))
        }
        follower.refresh()
        let stack = NSStackView(views: [list, reset, close, remote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let size = stack.fittingSize
        // Room for the line *Also delete the remote branches* adds once ticked.
        stack.frame = NSRect(x: 0, y: 0, width: max(380, size.width), height: size.height + 32)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sweep").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        withExtendedLifetime(follower) {}
        guard answer == .alertFirstButtonReturn else { return nil }
        return TaskSweepOptions(resetBranches: reset.state == .on, closePullRequests: close.state == .on,
                                deleteRemoteBranches: remote.state == .on)
    }
}

/// The target of the sweep confirmation's boxes: each change rewrites the list, so it says what the button would do.
@MainActor
private final class SweepConfirmationFollower: NSObject {
    private let update: () -> Void

    init(_ update: @escaping () -> Void) {
        self.update = update
    }

    func refresh() { update() }

    @objc func changed(_ sender: Any?) { update() }
}
