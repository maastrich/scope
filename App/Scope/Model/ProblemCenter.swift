import Foundation
import ScopeCore
import ScopeDrivers

/// The list behind the toolbar badge and popover: every non-modal failure or notice, newest last.
@MainActor
@Observable
final class ProblemCenter {
    private(set) var problems: [Problem] = []
    /// Problems reported since the popover was last opened.
    private(set) var unreadCount = 0
    /// Failures of something the user just asked for, shown as toasts over the scene until dismissed (newest last,
    /// three at most): a badge alone left *Add repo* failing with nothing on screen.
    private(set) var toasts: [Problem] = []
    /// Runs a problem's action button. Set by `AppModel`.
    @ObservationIgnored var onAction: (@MainActor (ProblemAction) -> Void)?

    /// Adds a problem (and logs it so a bug report carries the story).
    func report(_ problem: Problem) {
        problems.append(problem)
        unreadCount += 1
        switch problem.severity {
        case .error:
            Log.app.error("\(problem.title, privacy: .public): \(problem.detail ?? "", privacy: .public)")
        case .warning:
            Log.app.warning("\(problem.title, privacy: .public): \(problem.detail ?? "", privacy: .public)")
        case .info:
            Log.app.info("\(problem.title, privacy: .public)")
        }
    }

    /// A launch failure, with Retry / Re-probe shell / Open Settings actions.
    func report(_ error: LaunchError, thread: ThreadID, scope: ScopeID? = nil) {
        report(Problem(
            severity: .error,
            title: error.title,
            detail: error.detail,
            scopeID: scope,
            threadID: thread,
            actions: [
                ProblemAction(title: "Retry", kind: .retryLaunch(thread)),
                ProblemAction(title: "Re-probe Shell", kind: .reprobeShell),
                ProblemAction(title: "Open Settings", kind: .openSettings),
            ]
        ))
    }

    /// A one-line convenience for warnings.
    func warn(_ title: String, detail: String? = nil, scope: ScopeID? = nil, actions: [ProblemAction] = []) {
        report(Problem(severity: .warning, title: title, detail: detail, scopeID: scope, actions: actions))
    }

    /// A one-line convenience for errors. `toast` also puts it on screen, for a failure of an action the user started.
    func error(_ title: String, detail: String? = nil, scope: ScopeID? = nil, actions: [ProblemAction] = [], toast: Bool = false) {
        let problem = Problem(severity: .error, title: title, detail: detail, scopeID: scope, actions: actions)
        report(problem)
        if toast {
            toasts.append(problem)
            if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        }
    }

    func dismiss(_ id: UUID) {
        problems.removeAll { $0.id == id }
        dismissToast(id)
    }

    /// The toast goes; the problem stays in the popover.
    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// Drops every problem attached to a thread (it was closed).
    func dismissAll(thread: ThreadID) {
        problems.removeAll { $0.threadID == thread }
    }

    func markAllRead() {
        unreadCount = 0
    }
}
