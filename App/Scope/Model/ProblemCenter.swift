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
    /// The slug of a scope, for the event journal (which keeps slugs, never names or folders). Set by `AppModel`.
    @ObservationIgnored var scopeSlug: (@MainActor (ScopeID) -> String?)?

    /// Adds a problem (and logs it so a bug report carries the story). `title` is the title as the call site wrote it,
    /// when it went through `warn` or `error`: the journal keeps its literal words. `file` and `function` name the
    /// call site, which is how the journal tells problems apart.
    func report(_ problem: Problem, title: ProblemTitle? = nil, toast: Bool = false,
                file: String = #fileID, function: String = #function) {
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
        Journal.record(JournalEvent(
            kind: .problem, name: Self.site(file: file, function: function), title: title,
            outcome: toast ? "toast" : nil, cause: ProblemCause.classify(problem.detail).rawValue,
            severity: problem.severity.rawValue, scope: problem.scopeID.flatMap { scopeSlug?($0) },
            task: Self.taskID(of: problem), thread: problem.threadID?.rawValue
        ))
    }

    /// `appmodel+tasks:performsetup` for `Scope/Model/AppModel+Tasks.swift` and `performSetup(_:runCommands:only:)`:
    /// stable across edits that move lines, and an identifier the journal keeps.
    static func site(file: String, function: String) -> String {
        let name = file.split(separator: "/").last.map { String($0.dropLast(".swift".count)) } ?? file
        let base = function.prefix { $0 != "(" }
        return "\(name):\(base)".lowercased()
    }

    /// The task a problem is about, read from the action that would act on it.
    private static func taskID(of problem: Problem) -> String? {
        for action in problem.actions {
            switch action.kind {
            case .rerunTaskSetup(let id), .retryTaskCleanup(let id), .reopenTask(let id): return id
            default: continue
            }
        }
        return nil
    }

    /// A launch failure, with Retry / Re-probe shell / Open Settings actions.
    func report(_ error: LaunchError, thread: ThreadID, scope: ScopeID? = nil, file: String = #fileID, function: String = #function) {
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
        ), file: file, function: function)
    }

    /// A one-line convenience for warnings.
    func warn(_ title: ProblemTitle, detail: String? = nil, scope: ScopeID? = nil, actions: [ProblemAction] = [],
              file: String = #fileID, function: String = #function) {
        report(Problem(severity: .warning, title: title.text, detail: detail, scopeID: scope, actions: actions),
               title: title, file: file, function: function)
    }

    /// A one-line convenience for errors. `toast` also puts it on screen, for a failure of an action the user started.
    func error(_ title: ProblemTitle, detail: String? = nil, scope: ScopeID? = nil, actions: [ProblemAction] = [], toast: Bool = false,
               file: String = #fileID, function: String = #function) {
        let problem = Problem(severity: .error, title: title.text, detail: detail, scopeID: scope, actions: actions)
        report(problem, title: title, toast: toast, file: file, function: function)
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
