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

    /// The tab the task's agents drive, if one was opened.
    func agentSession(of task: TaskID) -> BrowserSession? {
        sessions(of: task).first { $0.kind == .agent }
    }

    /// The task's tab already on `url`'s server.
    func session(of task: TaskID, serving url: URL) -> BrowserSession? {
        // The agent's tab is its own: a link the user clicks never lands in it.
        sessions(of: task).filter { $0.kind == .user }.first { tab in tab.url.map { BrowserRoute.sameServer($0, url) } ?? false }
            .map { candidate in
                tabs.tab(of: task.rawValue, serving: url).flatMap { sessions[$0.id] }.flatMap { $0.kind == .user ? $0 : nil } ?? candidate
            }
    }

    func add(_ session: BrowserSession) {
        sessions[session.id] = session
        tabs.open(session.id, in: session.taskID.rawValue, url: session.url, agent: session.kind == .agent,
                  select: session.kind == .user)
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
