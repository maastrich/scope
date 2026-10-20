import AppKit
import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// The task's shell pane (spec §7): a login shell of the task in the reading column, opened by ⌃`, the Task menu,
/// the palette; several as tabs; closed with the task.
extension AppModel {
    /// The shells of the current task, in tab order.
    var currentTaskShells: [TaskShellSession] {
        currentTask.map { taskShells.sessions(of: $0.id) } ?? []
    }

    var currentTaskShell: TaskShellSession? {
        currentTask.flatMap { taskShells.selected(of: $0.id) }
    }

    /// ⌃`: the pane comes up — with a first shell when the task has none — or goes away when it is what is shown.
    /// Coming back from the diff ⌘D put over it leaves the diff behind the back button.
    func toggleTaskShell() {
        guard let task = currentTask else { return }
        if shownViewer == .shell {
            inspector.closeViewer()
            AppDelegate.refocusTerminal()
            return
        }
        if taskShells.sessions(of: task.id).isEmpty {
            openTaskShell(in: task)
        } else {
            inspector.show(.shell)
        }
        Usage.click("task.shell.toggle", label: "Toggle the task's shell pane")
    }

    /// `+` on the tabs, or the first ⌃`: a new shell of the task, shown at once; its process starts once the plan is
    /// known (the login shell's environment is cached after the first thread).
    func openTaskShell(in task: TaskState) {
        guard !task.isArchived, let scope = scope(task.scopeID) else { return }
        let record = task.record
        let session = TaskShellSession(taskID: task.id, shell: ShellEnvironment.loginShell(), cwd: record.threadCwd.path)
        session.onExit = { [weak self] session in self?.taskShellExited(session) }
        session.onOpenLink = { [weak self] session, link in
            guard let self else { return false }
            return self.openFileLink(link, scope: record.scopeID, task: self.task(session.taskID),
                                     directory: session.reportedDirectory ?? session.cwd)
        }
        taskShells.add(session)
        inspector.show(.shell)
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.launcher.taskShellPlan(task: record, scope: scope.declaration)
                guard self.taskShells.session(session.id) != nil else { return }
                session.launch(plan)
            } catch let error as LaunchError {
                session.fail(error)
            } catch {
                session.fail(.adapterSetupFailed(String(describing: error)))
            }
        }
    }

    func selectTaskShell(_ id: TaskShellID) {
        taskShells.select(id)
    }

    /// ✕ on a tab: the shell is hung up, whatever it was running.
    func closeTaskShell(_ id: TaskShellID) {
        guard let session = taskShells.remove(id) else { return }
        dismissShellPaneIfEmpty(task: session.taskID)
    }

    /// Archive, close: every shell of the task goes with it.
    func closeTaskShells(of taskID: TaskID) {
        taskShells.removeAll(of: taskID)
        dismissShellPaneIfEmpty(task: taskID)
    }

    /// Quit: every shell of every task is hung up, like the threads.
    func stopAllTaskShells() {
        for session in taskShells.allSessions { session.stop(escalateAfter: 1.5) }
    }

    /// The shell exited on its own (`exit`, ⌃D): its tab closes, as a terminal window does.
    private func taskShellExited(_ session: TaskShellSession) {
        taskShells.remove(session.id)
        dismissShellPaneIfEmpty(task: session.taskID)
    }

    /// The last shell of the task on screen is gone — or the task itself: back to what the pane covered, else nothing.
    private func dismissShellPaneIfEmpty(task taskID: TaskID) {
        guard inspector.viewer == .shell, taskShells.sessions(of: taskID).isEmpty,
              currentTask == nil || currentTask?.id == taskID else { return }
        if let previous = inspector.previousViewer, isShowable(previous) {
            inspector.goBack()
        } else {
            inspector.closeViewer()
        }
        AppDelegate.refocusTerminal()
    }
}
