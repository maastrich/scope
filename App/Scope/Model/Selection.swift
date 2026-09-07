import Foundation
import ScopeCore
import ScopeDrivers

/// What the sidebar highlights. Persisted by `UIStateStore`, so it is `Codable`.
enum SidebarItem: Hashable, Codable, Sendable {
    case scope(ScopeID)
    case repo(ScopeID, relativePath: String)
    case thread(ThreadID)

    /// The scope the item belongs to, when it is known from the item alone (threads need the model).
    var scopeID: ScopeID? {
        switch self {
        case .scope(let id), .repo(let id, _): id
        case .thread: nil
        }
    }

    var threadID: ThreadID? {
        if case .thread(let id) = self { return id }
        return nil
    }
}

/// The three inspector panels (Graph / Delta / Base). Only placeholders in M0.
enum InspectorTab: String, CaseIterable, Codable, Sendable, Hashable {
    case graph, delta, base
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
