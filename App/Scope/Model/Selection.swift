import Foundation
import ScopeAdapters
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

/// What the menu commands and the links of the app ask the inspector for (⌘D, ⇧⌘B, a task's menu, a notification):
/// a section to open and focus. The inspector itself is a column of `InspectorSection`s.
enum InspectorTab: String, CaseIterable, Sendable, Hashable {
    case delta, pullRequest, base

    var section: InspectorSection {
        switch self {
        case .delta: .delta
        case .pullRequest: .pullRequest
        case .base: .base
        }
    }
}

/// The scope-wide views, shown as a sheet over the window from the sidebar's buttons (⇧⌘P, ⌥⌘G, the palette).
enum GlobalSheet: String, Identifiable, Sendable, Hashable {
    case pullRequests, graph, inbox, compareAttempts
    var id: String { rawValue }

    /// The usage surface the sheet is recorded under.
    var usageSurface: (id: String, label: String) {
        switch self {
        case .pullRequests: ("sheet.pull-requests", "Pull Requests")
        case .graph: ("sheet.graph", "Graph")
        case .inbox: ("sheet.inbox", "Inbox")
        case .compareAttempts: ("sheet.compare-attempts", "Compare Attempts")
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
    /// Its activity file is deleted with the record; an undo writes this back.
    let activity: ThreadActivity
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
