import Foundation
import ScopeDrivers
import ScopeTasks

/// The shells of every task's shell pane: the tabs (`TaskShellTabs`, pure) and the sessions behind them.
/// Nothing here is persisted — a shell is a scratch terminal, gone with its tab, its task or the app.
@MainActor
@Observable
final class TaskShellStore {
    private(set) var tabs = TaskShellTabs()
    private var sessions: [TaskShellID: TaskShellSession] = [:]

    func session(_ id: TaskShellID) -> TaskShellSession? { sessions[id] }

    func sessions(of task: TaskID) -> [TaskShellSession] {
        tabs.tabs(of: task.rawValue).compactMap { sessions[$0.id] }
    }

    var allSessions: [TaskShellSession] { tabs.tabs.compactMap { sessions[$0.id] } }

    func selected(of task: TaskID) -> TaskShellSession? {
        tabs.selectedTab(of: task.rawValue).flatMap { sessions[$0.id] }
    }

    func add(_ session: TaskShellSession) {
        sessions[session.id] = session
        tabs.open(session.id, in: session.taskID.rawValue)
    }

    func select(_ id: TaskShellID) {
        tabs.select(id)
    }

    /// Hangs the shell up and drops its tab.
    @discardableResult
    func remove(_ id: TaskShellID) -> TaskShellSession? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        tabs.close(id)
        session.onExit = nil
        session.stop()
        return session
    }

    /// Every shell of the task, hung up: what an archive or a close does.
    @discardableResult
    func removeAll(of task: TaskID) -> [TaskShellSession] {
        tabs.closeAll(of: task.rawValue).compactMap { tab in
            guard let session = sessions.removeValue(forKey: tab.id) else { return nil }
            session.onExit = nil
            session.stop()
            return session
        }
    }
}
