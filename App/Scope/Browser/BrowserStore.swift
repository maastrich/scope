import Foundation
import ScopeCore
import ScopeTasks

/// The tabs of every task's Browser pane (`BrowserTabs`, pure) and the sessions behind them. Nothing is persisted
/// here: the pages' cookies and storage live in WebKit's store for the scope, the tabs go with the task or the app.
@MainActor
@Observable
final class BrowserStore {
    private(set) var tabs = BrowserTabs()
    private var sessions: [String: BrowserSession] = [:]

    func session(_ id: String) -> BrowserSession? { sessions[id] }

    func sessions(of task: TaskID) -> [BrowserSession] {
        tabs.tabs(of: task.rawValue).compactMap { sessions[$0.id] }
    }

    func selected(of task: TaskID) -> BrowserSession? {
        tabs.selectedTab(of: task.rawValue).flatMap { sessions[$0.id] }
    }

    /// The task's tab already on `url`'s server.
    func session(of task: TaskID, serving url: URL) -> BrowserSession? {
        tabs.tab(of: task.rawValue, serving: url).flatMap { sessions[$0.id] }
    }

    func add(_ session: BrowserSession) {
        sessions[session.id] = session
        tabs.open(session.id, in: session.taskID.rawValue, url: session.url)
        let previous = session.onNavigate
        session.onNavigate = { [weak self] session, url in
            self?.tabs.update(session.id, url: url)
            previous?(session, url)
        }
    }

    func select(_ id: String) {
        tabs.select(id)
    }

    @discardableResult
    func remove(_ id: String) -> BrowserSession? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        tabs.close(id)
        session.tearDown()
        return session
    }

    /// Every tab of the task, its views torn down: what an archive or a close does.
    func removeAll(of task: TaskID) {
        for tab in tabs.closeAll(of: task.rawValue) {
            sessions.removeValue(forKey: tab.id)?.tearDown()
        }
    }

    var allSessions: [BrowserSession] { tabs.tabs.compactMap { sessions[$0.id] } }
}
