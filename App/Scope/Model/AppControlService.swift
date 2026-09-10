import AppKit
import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks

/// The app side of the control socket: the only place where a `ControlCall` becomes something happening in
/// Scope. The `scope` CLI and `scope mcp` both arrive here, which is the point — one command layer, two
/// façades, no second implementation to keep in step.
///
/// It maps and nothing else: every rule lives in `AutomationPolicy`, every resolution in `ScopeResolver`,
/// and the work itself in `AppModel.newThread` / `TaskManager.create` — the same calls the UI makes.
@MainActor
final class AppControlService: ControlService {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var automation: AutomationSettings { model.config.preferences.automationSettings }

    /// A `SCOPE_THREAD` is only worth something when it names a thread this app is running: the variable
    /// lives in a process the user owns and anything under that account can write it.
    func origin(for caller: ControlCaller) -> ControlOrigin {
        guard let raw = caller.thread, !raw.isEmpty else { return .user }
        guard let id = ThreadID(rawValue: raw), let session = model.session(id) else {
            return .strangerThread(raw)
        }
        return .thread(id, depth: session.record.resolvedOrigin.depth)
    }

    func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool {
        let who: String = switch origin {
        case .user: "Something on your machine"
        case .thread(let id, let depth): "The agent in thread \(id.rawValue)\(depth == 0 ? "" : " (depth \(depth))")"
        case .strangerThread(let raw): "A process claiming to be thread \(raw)"
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Let an agent \(subject)?"
        alert.informativeText = "\(who) asked through \(caller.client). Nothing is created until you allow it."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Refuse")
        NSApp.requestUserAttention(.informationalRequest)
        return await AppControlService.ask(alert, timeout: automation.approvalTimeout)
    }

    func perform(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller,
                 progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
        switch call {
        case .ping:
            return .success(.ping(PingResult(app: "Scope", version: model.env.appVersion,
                                             home: model.env.home.path, automation: automation)))
        case .list(let params):
            return list(params)
        case .threadNew(let params):
            return await newThread(params, from: origin, caller: caller)
        case .taskNew(let params):
            return await newTask(params, from: origin, caller: caller, progress: progress)
        }
    }

    // MARK: Reading

    /// Every declared scope, in sidebar order.
    private var scopeSummaries: [ScopeSummary] {
        model.scopes.map { scope in
            ScopeSummary(id: scope.id.rawValue, slug: scope.declaration.slug, name: scope.name,
                         path: scope.url.path, status: scope.kind.rawValue, repos: scope.repos.map(\.id))
        }
    }

    private func list(_ params: ListParams) -> Result<ControlResultPayload, ControlError> {
        var scopes = scopeSummaries
        if let query = params.scope {
            switch ScopeResolver.resolve(query, in: scopes) {
            case .failure(let error): return .failure(error)
            case .success(let only): scopes = [only]
            }
        }
        let ids = Set(scopes.map(\.id))
        let wants = { (kind: ListParams.Kind) in params.kind == .all || params.kind == kind }
        let threads = wants(.threads) ? model.threads.filter { ids.contains($0.record.scopeID.rawValue) }.map(summary) : []
        let tasks = wants(.tasks) ? model.tasks.filter { ids.contains($0.record.scopeID.rawValue) }.map(summary) : []
        return .success(.list(ListResult(scopes: wants(.scopes) ? scopes : [], threads: threads, tasks: tasks)))
    }

    private func summary(_ session: ThreadSession) -> ThreadSummary {
        let scope = model.scope(session.record.scopeID)
        let origin = session.record.resolvedOrigin
        return ThreadSummary(
            id: session.id.rawValue, title: session.title, driver: session.record.driverID,
            scope: scope?.name ?? session.record.scopeRoot, scopeSlug: scope?.declaration.slug ?? "",
            task: session.record.taskID, cwd: session.record.cwd,
            state: session.displayState.name, alive: session.isAlive,
            openedBy: origin.client ?? origin.author.rawValue, depth: origin.depth
        )
    }

    private func summary(_ task: TaskState) -> TaskSummary {
        let scope = model.scope(task.scopeID)
        return TaskSummary(
            id: task.record.id.rawValue, name: task.name, slug: task.record.slug, branch: task.branch,
            scope: scope?.name ?? task.record.scopeName, scopeSlug: task.record.scopeSlug,
            root: task.record.root, repos: task.activeRepos.map(\.repoRelativePath),
            threads: model.threads(in: task.record.id).map(\.id.rawValue)
        )
    }

    // MARK: Writing

    private func newThread(_ params: ThreadNewParams, from origin: ControlOrigin,
                           caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        let resolved = ScopeResolver.resolve(params.scope, in: scopeSummaries,
                                             callerScopeID: callerScopeID, callerCwd: caller.cwd)
        guard case .success(let scope) = resolved else {
            return .failure(resolved.failureError)
        }
        guard let scopeID = model.scopes.first(where: { $0.id.rawValue == scope.id })?.id else {
            return .failure(.notFound("scope \(scope.slug) went away"))
        }
        if let driver = params.driver, model.profile(id: driver)?.id != driver {
            return .failure(.notFound("no driver profile “\(driver)”",
                                      detail: model.drivers.profiles.map(\.id).joined(separator: ", ")))
        }

        var cwdKind = ThreadCwdKind.scopeRoot
        var taskID: TaskID?
        if let query = params.task {
            guard let task = model.tasks.first(where: { $0.record.id.rawValue == query || $0.record.slug == query }),
                  task.scopeID == scopeID else {
                return .failure(.notFound("no task “\(query)” in \(scope.slug)",
                                          detail: model.tasks.filter { $0.scopeID == scopeID }.map(\.record.slug).joined(separator: ", ")))
            }
            taskID = task.record.id
        } else if let repo = params.repo {
            switch ScopeResolver.resolveRepo(repo, in: scope) {
            case .failure(let error): return .failure(error)
            case .success(let path): cwdKind = .repoBase(relativePath: path == "." ? "" : path)
            }
        }

        let parent: String? = if case .thread(let id, _) = origin { id.rawValue } else { nil }
        let threadOrigin = ThreadOrigin(author: .control, parent: parent,
                                        depth: AutomationPolicy.childDepth(of: origin), client: caller.client)
        guard let session = await model.newThread(in: scopeID, driverID: params.driver, cwdKind: cwdKind,
                                                  taskID: taskID, title: params.title, initialPrompt: params.prompt,
                                                  origin: threadOrigin) else {
            return .failure(.failed("Scope could not open the thread",
                                    detail: "The app reported it as a problem; its window says why."))
        }
        // A bounce in the Dock, not a focus steal: an agent opening a thread should be noticed, not obeyed.
        NSApp.requestUserAttention(.informationalRequest)
        return .success(.thread(ThreadNewResult(
            thread: session.id.rawValue, title: session.title, driver: session.record.driverID,
            scope: scope.name, scopeSlug: scope.slug, cwd: session.record.cwd,
            task: session.record.taskID, depth: threadOrigin.depth
        )))
    }

    private func newTask(_ params: TaskNewParams, from origin: ControlOrigin, caller: ControlCaller,
                         progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
        .failure(.init(.unsupported, "task.new is not in this build yet"))
    }

    /// Runs an alert and answers `false` if nobody touched it before `timeout` seconds.
    private static func ask(_ alert: NSAlert, timeout: Int) async -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            // No window to hang a sheet on: a modal run is what the rest of the app does too.
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            let answered = Answered()
            alert.beginSheetModal(for: window) { response in
                answered.finish(continuation, response == .alertFirstButtonReturn)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak window] in
                guard !answered.isDone else { return }
                window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            }
        }
    }

    /// Resumes the confirmation exactly once, whether the user answered or the deadline did.
    private final class Answered: @unchecked Sendable {
        private var done = false
        var isDone: Bool { done }

        func finish(_ continuation: CheckedContinuation<Bool, Never>, _ value: Bool) {
            guard !done else { return }
            done = true
            continuation.resume(returning: value)
        }
    }
}

private extension Result where Failure == ControlError {
    /// The error of a `Result` known to have failed.
    var failureError: ControlError {
        if case .failure(let error) = self { return error }
        return .failed("unexpected success")
    }
}
