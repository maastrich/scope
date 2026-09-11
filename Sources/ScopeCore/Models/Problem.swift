import Foundation

/// A non-modal, user-visible failure or notice (toolbar badge + popover, mirrored in the pane concerned).
///
/// UI-agnostic on purpose: `ScopeCore` produces problems, the app's `ProblemCenter` shows them and
/// runs their `actions`.
public struct Problem: Identifiable, Sendable, Equatable {
    public enum Severity: String, Sendable, Hashable, CaseIterable {
        case info, warning, error
    }

    public let id: UUID
    public var severity: Severity
    /// One line, e.g. `"claude not found in PATH"`.
    public var title: String
    /// Multi-line, copyable.
    public var detail: String?
    public var scopeID: ScopeID?
    public var threadID: ThreadID?
    public var actions: [ProblemAction]
    public var createdAt: Date

    public init(
        severity: Severity = .error,
        title: String,
        detail: String? = nil,
        scopeID: ScopeID? = nil,
        threadID: ThreadID? = nil,
        actions: [ProblemAction] = [],
        createdAt: Date = .now,
        id: UUID = UUID()
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.scopeID = scopeID
        self.threadID = threadID
        self.actions = actions
        self.createdAt = createdAt
    }
}

/// A button offered on a `Problem`.
public struct ProblemAction: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case retryLaunch(ThreadID)
        case reprobeShell
        case openSettings
        case revealFile(String)
        case rescan(ScopeID)
        case locateScope(ScopeID)
        /// Runs a task's setup again; the payload is the task id.
        case rerunTaskSetup(String)
        case dismiss
    }

    public let id: UUID
    public var title: String
    public var kind: Kind

    public init(title: String, kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    /// `"Dismiss"`
    public static var dismiss: ProblemAction {
        ProblemAction(title: "Dismiss", kind: .dismiss)
    }

    /// `"Reveal in Finder"` for `path`.
    public static func reveal(_ path: String, title: String = "Reveal in Finder") -> ProblemAction {
        ProblemAction(title: title, kind: .revealFile(path))
    }
}
