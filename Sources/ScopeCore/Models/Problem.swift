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
    /// Why it happened, when the call site knows: read from the error's type (`ProblemCause.of`). `nil` leaves
    /// `journalCause` to work it out.
    public var cause: ProblemCause?

    public init(
        severity: Severity = .error,
        title: String,
        detail: String? = nil,
        scopeID: ScopeID? = nil,
        threadID: ThreadID? = nil,
        actions: [ProblemAction] = [],
        createdAt: Date = .now,
        cause: ProblemCause? = nil,
        id: UUID = UUID()
    ) {
        self.cause = cause
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

extension Problem {
    /// The cause the event journal keeps: the one the call site gave, `notice` for a notice that reports no failure,
    /// else what the detail reads as. `unknown` only for a failure that said nothing.
    public var journalCause: ProblemCause {
        if let cause { return cause }
        if severity == .info { return .notice }
        return ProblemCause.classify(detail)
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
        /// Runs a task's interrupted archive or close again; the payload is the task id.
        case retryTaskCleanup(String)
        /// Brings an archived task back with the changes saved when it was archived; the payload is the task id.
        case reopenTask(String)
        case dismiss
    }

    public let id: UUID
    public var title: String
    public var kind: Kind

    /// The element of the button in the usage log: one per kind, never the payload (ids, paths).
    public var usageElement: String {
        switch kind {
        case .retryLaunch: "retry-launch"
        case .reprobeShell: "reprobe-shell"
        case .openSettings: "open-settings"
        case .revealFile: "reveal-file"
        case .rescan: "rescan"
        case .locateScope: "locate-scope"
        case .rerunTaskSetup: "rerun-task-setup"
        case .retryTaskCleanup: "retry-task-cleanup"
        case .reopenTask: "restore-task"
        case .dismiss: "dismiss"
        }
    }

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
