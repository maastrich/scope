import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// What the sidebar highlights. Persisted by `UIStateStore`, so it is `Codable`.
enum SidebarItem: Hashable, Codable, Sendable {
    case scope(ScopeID)
    case repo(ScopeID, relativePath: String)
    case thread(ThreadID)
    case task(TaskID)

    /// The scope the item belongs to, when it is known from the item alone (threads need the model).
    var scopeID: ScopeID? {
        switch self {
        case .scope(let id), .repo(let id, _): id
        case .thread, .task: nil
        }
    }

    var taskID: TaskID? {
        if case .task(let id) = self { return id }
        return nil
    }

    var threadID: ThreadID? {
        if case .thread(let id) = self { return id }
        return nil
    }
}

/// The inspector panels: Graph / Delta / Base / PRs.
enum InspectorTab: String, CaseIterable, Codable, Sendable, Hashable {
    case graph, delta, base, pullRequests

    /// Segmented-control label.
    var title: String {
        switch self {
        case .graph: "Graph"
        case .delta: "Delta"
        case .base: "Base"
        case .pullRequests: "PRs"
        }
    }
}

/// Where ⌘T opens the next thread, derived from the sidebar selection (`AppModel.newThreadTarget`).
enum NewThreadTarget {
    case scopeRoot(ScopeState)
    case repoBase(ScopeState, relativePath: String)
    case task(TaskState)
}

/// A thread closed by the user, kept for 30 s so ⇧⌘T can bring it back (`AppModel.undoCloseThread`).
struct ClosedThread: Identifiable {
    let record: ThreadRecord
    let profile: DriverProfile
    /// Sidebar item selected before the close (informational; the undo selects the thread).
    let selection: SidebarItem?
    var id: ThreadID { record.id }
}

/// What `applicationShouldTerminate` does with running threads.
enum TerminationDecision: Equatable, Sendable {
    case now
    case askUser(running: Int)
}

/// The login-shell probe as seen by the UI.
enum ShellStatus: Equatable, Sendable {
    case probing
    case ready(ResolvedShellEnvironment)
    case fallback(ResolvedShellEnvironment)
}
