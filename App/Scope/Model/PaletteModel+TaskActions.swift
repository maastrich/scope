import AppKit
import Foundation
import ScopeCore
import ScopeTasks

/// What the palette can do to a task, not only go to it. Every row calls what the task's context menu calls; none
/// asks first: an archive saves what it removes, and *Restore Archived Task…* brings it back.
@MainActor
extension PaletteModel {
    /// The current task's actions.
    static func taskActions(_ model: AppModel, task: TaskState) -> [PaletteItem] {
        var items: [PaletteItem] = []
        // One row per pull request, the repository named when the task has several, so each opens the right page.
        let several = task.record.pullRequests.count > 1
        for pr in task.record.pullRequests {
            let where_ = several ? (model.repo(of: pr, in: task).map { "\($0.name) " } ?? "") : ""
            items.append(PaletteItem(id: "task-open-pr-\(pr.url.path)", section: .actions, icon: "arrow.triangle.pull",
                                     label: several ? "Open Pull Request \(where_)\(pr.label) in Browser" : "Open Pull Request in Browser",
                                     hint: "\(pr.label) \(pr.title)" + (pr.isOpen ? "" : " · \(pr.state ?? "")")) {
                model.openOnGitHub(pr.url)
            })
        }
        items.append(PaletteItem(id: "task-copy-branch", section: .actions, icon: "doc.on.doc", label: "Copy Branch Name",
                                 hint: task.branch) { Pasteboard.copy(task.branch) })
        if !task.isArchived {
            items.append(PaletteItem(id: "task-shell", section: .actions, icon: "terminal", label: "Shell",
                                     hint: "a shell of \(task.name) in the reading column", shortcut: "⌃`") {
                model.toggleTaskShell()
            })
        }
        if !task.isArchived {
            items.append(PaletteItem(id: "task-add-branch", section: .actions, icon: "arrow.triangle.branch", label: "Add Branch…",
                                     hint: "a second worktree of a repository of \(task.name), on its own branch") {
                model.addBranchFromUI(task)
            })
            for sandbox in task.activeSandboxes.filter(\.isSecondary) {
                let label = sandbox.sandboxLabel(scopeName: task.record.scopeName)
                items.append(PaletteItem(id: "task-branch-thread-\(sandbox.sandboxKey)", section: .actions, icon: "terminal",
                                         label: "New Thread on \(sandbox.branch)", hint: label) {
                    Task { _ = await model.newThread(in: task.scopeID, taskID: task.id, branch: sandbox.branch) }
                })
                items.append(PaletteItem(id: "task-branch-remove-\(sandbox.sandboxKey)", section: .actions, icon: "xmark.circle",
                                         label: "Remove Branch \(sandbox.branch)", hint: "\(label) · uncommitted changes saved, branch kept") {
                    model.removeBranchFromUI(sandbox, of: task)
                })
            }
        }
        items.append(PaletteItem(id: "task-set-topic", section: .actions, icon: "tag", label: "Set Topic…",
                                 hint: task.record.topic.map { "now “\($0)”" } ?? task.name) {
            guard let name = model.promptTopicName(title: "Set Topic", current: task.record.topic, action: "File") else { return }
            Task { await model.fileTasks([task.id], underTopic: name) }
        })
        // The Topic submenu's list, one row per topic in use, so filing next to a sibling is two keystrokes.
        let current = task.record.topic.map(TaskTopic.key)
        for topic in model.topics(in: task.scopeID) where TaskTopic.key(topic) != current {
            items.append(PaletteItem(id: "task-topic-\(TaskTopic.key(topic))", section: .actions, icon: "tag",
                                     label: "File Under “\(topic)”", hint: task.name) {
                Task { await model.fileTasks([task.id], underTopic: topic) }
            })
        }
        if let topic = task.record.topic {
            items.append(PaletteItem(id: "task-remove-topic", section: .actions, icon: "tag.slash", label: "Remove from Topic",
                                     hint: "“\(topic)”") {
                Task { await model.fileTasks([task.id], underTopic: nil) }
            })
        }
        if let attempt = task.record.attempt, !task.isArchived {
            items.append(PaletteItem(id: "task-compare-attempts", section: .actions, icon: "rectangle.split.3x1",
                                     label: "Compare Attempts…", hint: "\(attempt.count) attempts of \(attempt.baseName)") {
                model.presentCompare(group: attempt.group)
            })
            items.append(PaletteItem(id: "task-keep-attempt", section: .actions, icon: "checkmark.seal",
                                     label: "Keep This Attempt", hint: "rename to “\(attempt.baseName)”, archive the others") {
                Task { await model.keepAttempt(task) }
            })
        }
        items.append(PaletteItem(id: "task-archive", section: .actions, icon: "archivebox", label: "Archive Task",
                                 hint: task.name) {
            Task { await model.archiveTask(task.id) }
        })
        return items
    }

    /// The archived tasks of `scope` a restore can bring back, the last archived first. One whose archive did not
    /// finish is left out: the task manager would hand it back as it is.
    static func restorableTasks(_ model: AppModel, in scope: ScopeID) -> [TaskState] {
        model.tasks
            .filter { $0.scopeID == scope && $0.record.isArchived && $0.record.cleanup == nil && !$0.isDismantling }
            .sorted { ($0.record.archivedAt ?? .distantPast) > ($1.record.archivedAt ?? .distantPast) }
    }

    /// The *Restore Archived Task…* picker: the current scope's archived tasks, each brought back by the archive
    /// notice's own Restore.
    static func archivedTaskItems(_ model: AppModel) -> [PaletteItem] {
        guard let scope = model.currentScope else { return [] }
        return restorableTasks(model, in: scope.id).map { task in
            let archived = task.record.archivedAt.map { "archived " + $0.formatted(.relative(presentation: .named)) }
            return PaletteItem(id: "restore-\(task.id.rawValue)", section: .archivedTasks, icon: "arrow.uturn.backward",
                               label: task.name, hint: [task.branch, task.record.topic, archived].compactMap { $0 }.joined(separator: " · ")) {
                Task { await model.reopenTask(task.id) }
            }
        }
    }
}
