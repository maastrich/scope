import Foundation
import ScopeAdapters
import ScopeCore
import ScopeGit
import ScopeTasks

/// Checkpoints per turn (spec §4.3): every `turn.ended` or `turn.failed` of a thread in a task snapshots the task's
/// sandboxes (`TaskCheckpoints`); the Task section lists them and offers the diff, the restore and a branch.
extension AppModel {
    /// A turn ended in `session`: its task gets a checkpoint once the turns ending seconds apart have settled — two
    /// threads answering together, a driver that fires twice. The latest turn's words name the checkpoint.
    func scheduleCheckpoint(after session: ThreadSession) {
        guard let task = task(of: session), !task.isArchived, let turn = session.activity.turns.last,
              turn.outcome == .ended || turn.outcome == .failed else { return }
        let info = TaskCheckpoints.TurnInfo(threadID: session.id.rawValue, threadTitle: session.title,
                                            turn: session.activity.turns.count, endedAt: turn.endedAt, said: turn.said)
        checkpointJobs[task.id]?.cancel()
        checkpointJobs[task.id] = Task { [weak self] in
            try? await Task.sleep(for: TaskCheckpoints.debounce)
            guard !Task.isCancelled, let self else { return }
            await self.takeCheckpoint(of: task, turn: info)
        }
    }

    private func takeCheckpoint(of task: TaskState, turn: TaskCheckpoints.TurnInfo) async {
        checkpointJobs[task.id] = nil
        guard !task.isArchived else { return }
        do {
            if try await env.tasks.checkpoints.snapshot(task.record, turn: turn) != nil {
                await reloadCheckpoints(of: task.id)
            }
        } catch {
            Log.tasks.error("checkpoint of \(task.record.slug, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    func reloadCheckpoints(of taskID: TaskID) async {
        let list = await env.tasks.checkpoints.list(taskID)
        guard let task = task(taskID) else { return }
        task.checkpoints = list
        task.checkpointsLoaded = true
        for session in threads(in: taskID) { refreshReading(for: session) }
    }

    /// *Show diff*: the checkpoint against the sandboxes as they are now, in the reading column.
    func readCheckpointDiff(_ checkpoint: TaskCheckpoint, of task: TaskState) async {
        Usage.click("task.checkpoint-diff", label: "Show a checkpoint's diff")
        do {
            let diffs = try await env.tasks.checkpoints.diff(task.record, number: checkpoint.number)
            showReading(ReadingContent(
                kind: .checkpoint(task.id, checkpoint.number), title: "\(task.name) · checkpoint \(checkpoint.number)", at: checkpoint.at,
                markdown: Self.checkpointDiffMarkdown(checkpoint, diffs: diffs, task: task.record),
                directory: task.record.threadCwd.path, taskID: task.id, scopeID: task.scopeID
            ))
        } catch {
            problems.error("Could not read checkpoint \(checkpoint.number) of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// The *Changes* row of a reply: the turn's checkpoint, as *Show diff* opens it.
    func openChanges(_ changes: ReadingTurn.Changes) {
        guard let task = task(changes.taskID),
              let checkpoint = task.checkpoints.first(where: { $0.number == changes.number }) else { return }
        Task { await readCheckpointDiff(checkpoint, of: task) }
    }

    /// *Restore files*, from the Task section: no question asked — the state replaced is itself a checkpoint, and the
    /// notice says which.
    func restoreCheckpointFromUI(_ checkpoint: TaskCheckpoint, of task: TaskState) async {
        Usage.click("task.checkpoint-restore", label: "Restore a checkpoint's files")
        do {
            let result = try await restoreCheckpoint(checkpoint.number, of: task)
            let undo = result.undo.map { " — the files as they were are checkpoint \($0.number)" } ?? ""
            problems.report(Problem(severity: .info, title: "Restored checkpoint \(checkpoint.number) of \(task.name)",
                                    detail: "Every sandbox has the files as the checkpoint had them; the branch and its commits did not move\(undo)."))
        } catch {
            problems.error("Could not restore checkpoint \(checkpoint.number) of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// The restore itself, shared with `task.restore-checkpoint`: the task's rows refresh with the new files.
    @discardableResult
    func restoreCheckpoint(_ number: Int, of task: TaskState) async throws -> TaskCheckpoints.Restoration {
        let result = try await env.tasks.checkpoints.restore(task.record, number: number)
        await reloadCheckpoints(of: task.id)
        task.refresh()
        if currentTask?.id == task.id { await delta.load(task: task) }
        return result
    }

    /// *Branch from here*: `<branch>-cp<n>` at the checkpoint's commit, nothing checked out.
    func branchFromCheckpoint(_ checkpoint: TaskCheckpoint, of task: TaskState) async {
        Usage.click("task.checkpoint-branch", label: "Branch from a checkpoint")
        do {
            let name = try await env.tasks.checkpoints.branch(task.record, from: checkpoint.number)
            problems.report(Problem(severity: .info, title: "Created \(name) at checkpoint \(checkpoint.number)",
                                    detail: "The branch points at the checkpoint's commit in every repository of the task; nothing was checked out."))
            scope(task.scopeID)?.refreshFacts()
        } catch {
            problems.error("Could not branch from checkpoint \(checkpoint.number) of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// The diff as the reading column shows it: a heading per sandbox when the task has several, a fenced `diff`
    /// block per file. `+` is what the working tree has now, `−` what the checkpoint had.
    static func checkpointDiffMarkdown(_ checkpoint: TaskCheckpoint, diffs: [TaskCheckpoints.RepoDiff], task: TaskRecord) -> String {
        var lines: [String] = []
        var head = "**Checkpoint \(checkpoint.number)**"
        if let title = checkpoint.threadTitle { head += " · \(title)" }
        if let turn = checkpoint.turn { head += ", turn \(turn)" }
        head += " · " + checkpoint.at.formatted(date: .abbreviated, time: .shortened)
        lines.append(head)
        if let said = checkpoint.said, !said.isEmpty { lines += ["", "> \(said)"] }
        let files = diffs.flatMap(\.files)
        guard !files.isEmpty else {
            lines += ["", "The sandbox is exactly as this checkpoint left it."]
            return lines.joined(separator: "\n")
        }
        let summary = DiffSummary(files)
        lines += ["", "Against the sandbox now — `+` is what the working tree has, `−` what the checkpoint had: "
                  + "\(summary.files) \(summary.files == 1 ? "file" : "files"), +\(summary.additions) −\(summary.deletions)."]
        for repo in diffs where !repo.files.isEmpty {
            if diffs.count > 1 {
                lines += ["", "## \(repo.repoRelativePath == "." ? task.scopeName : repo.repoRelativePath)"]
            }
            for file in repo.files {
                var heading = "### \(file.path)"
                if file.status == .added { heading += " (new)" } else if file.status == .deleted { heading += " (gone)" }
                if let old = file.oldPath, old != file.path { heading += " ← \(old)" }
                lines += ["", heading]
                if file.hasHunks {
                    lines += ["", "```diff", file.unifiedPatch.trimmingCharacters(in: .newlines), "```"]
                } else {
                    lines += ["", file.isBinary ? "Binary file." : "No text change to show."]
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
