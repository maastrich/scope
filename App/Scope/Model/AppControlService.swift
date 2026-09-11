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
        AutomationPolicy.origin(of: caller) { [model] id in model.session(id)?.record.resolvedOrigin.depth }
    }

    func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool {
        let who: String = switch origin {
        case .user: "Something on your machine"
        case .thread(let id, let depth): "The agent in thread \(id.rawValue)\(depth == 0 ? "" : " (depth \(depth))")"
        case .strangerThread(let raw): "A process claiming to be thread \(raw)"
        case .externalAgent: "An agent running outside Scope"
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
        case .threadStop(let params):
            return act(on: params.thread, from: origin) { session in
                guard session.isAlive else { return .failure(.failed("thread \(session.id.rawValue) is not running")) }
                model.stop(session.id)
                return .success(.action(ActionResult(message: "stopped \(session.id.rawValue) — \(session.title)",
                                                     thread: session.id.rawValue), .threadStop))
            }
        case .threadClose(let params):
            switch target(params.thread, from: origin) {
            case .failure(let error): return .failure(error)
            case .success(let session):
                // Asked for explicitly: no "close a running thread?" sheet for the caller to wait on.
                _ = await model.close(session.id, force: true)
                return .success(.action(ActionResult(message: "closed \(session.id.rawValue) — \(session.title)",
                                                     thread: session.id.rawValue), .threadClose))
            }
        case .threadSend(let params):
            return act(on: params.thread, from: origin) { session in
                guard session.isAlive else { return .failure(.failed("thread \(session.id.rawValue) is not running")) }
                session.send(params.text + (params.submit ? "\r" : ""))
                return .success(.action(ActionResult(message: "typed \(params.text.count) characters into \(session.id.rawValue)"
                                                         + (params.submit ? " and pressed ↩" : ""),
                                                     thread: session.id.rawValue), .threadSend))
            }
        case .threadRead(let params):
            // The gate is `thread.send`'s: only a thread the caller opened, any thread from the user's own terminal.
            return act(on: params.thread, from: origin) { session in
                let transcript = TerminalBridge.transcript(of: session)
                let page = ThreadTranscript.page(transcript.lines, firstLineNumber: transcript.firstLineNumber,
                                                 count: params.lines, cursor: params.cursor)
                return .success(.read(ThreadReadResult(thread: session.id.rawValue, title: session.title,
                                                       state: session.displayState.name, page: page)))
            }
        case .taskClose(let params):
            guard let task = model.tasks.first(where: { $0.record.id.rawValue == params.task || $0.record.slug == params.task }) else {
                return .failure(.notFound("no task “\(params.task)”", detail: model.tasks.map(\.record.slug).joined(separator: ", ")))
            }
            let slug = task.record.slug
            do {
                try await model.removeTask(task.id, deleteBranch: params.deleteBranch, force: params.force)
            } catch {
                return .failure(.failed("could not close the task \(slug)", detail: String(describing: error)))
            }
            return .success(.action(ActionResult(message: "closed the task \(slug)"
                                                     + (params.deleteBranch ? " and deleted its branch" : "; its branch is kept"),
                                                 task: task.record.id.rawValue), .taskClose))
        }
    }

    /// The thread `raw` names, when `origin` may act on it (`AutomationPolicy.mayTouch`).
    private func target(_ raw: String, from origin: ControlOrigin) -> Result<ThreadSession, ControlError> {
        guard let id = ThreadID(rawValue: raw), let session = model.session(id) else {
            return .failure(.notFound("no thread “\(raw)”", detail: "`scope list threads` shows the ids."))
        }
        if let refusal = AutomationPolicy.mayTouch(session.record.resolvedOrigin, from: origin) {
            return .failure(refusal)
        }
        return .success(session)
    }

    private func act(on raw: String, from origin: ControlOrigin,
                     _ body: (ThreadSession) -> Result<ControlResultPayload, ControlError>) -> Result<ControlResultPayload, ControlError> {
        switch target(raw, from: origin) {
        case .failure(let error): .failure(error)
        case .success(let session): body(session)
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

    /// `scope task new` — the New Task sheet without the sheet: the same request resolution, the same
    /// headless proposal, the same `TaskManager.create`. What an agent gets is what the user would have got.
    private func newTask(_ params: TaskNewParams, from origin: ControlOrigin, caller: ControlCaller,
                         progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        let resolved = ScopeResolver.resolve(params.scope, in: scopeSummaries,
                                             callerScopeID: callerScopeID, callerCwd: caller.cwd)
        guard case .success(let summary) = resolved else { return .failure(resolved.failureError) }
        guard let scope = model.scopes.first(where: { $0.id.rawValue == summary.id }) else {
            return .failure(.notFound("scope \(summary.slug) went away"))
        }
        let prompt = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(.badRequest("a task needs a prompt")) }

        // What the prompt is about, before anything is created: a pull request it names wins over everything.
        let request = await model.resolveTaskRequest(prompt: prompt, in: scope.id)
        if let existing = request.existingTask {
            return .failure(.init(.failed, "that pull request already has a task",
                                  detail: "Task \(existing.rawValue) in \(summary.slug)."))
        }
        if let unresolved = request.unresolved {
            return .failure(.badRequest("the pull request in the prompt could not be read", detail: unresolved))
        }

        var repos: [String] = []
        for query in params.repos {
            switch ScopeResolver.resolveRepo(query, in: summary) {
            case .failure(let error): return .failure(error)
            case .success(let path): repos.append(path)
            }
        }
        if repos.isEmpty { repos = request.repos }

        let evidence = await model.branchEvidence(for: repos, in: scope.id)
        var proposal: TaskProposal
        if let branch = params.branch, let title = params.title {
            proposal = TaskProposal(title: title, slug: params.slug ?? title, branch: branch, repos: repos,
                                    source: .derived(reason: "named by the client"))
        } else {
            progress("asking \(model.profile(id: params.driver)?.name ?? "the driver") what to call it")
            proposal = await model.proposeTask(prompt: prompt, driverID: params.driver, repos: repos,
                                               evidence: evidence, in: scope.id)
            if let title = params.title { proposal.title = title }
            if let branch = params.branch { proposal.branch = branch }
            if let slug = params.slug { proposal.slug = slug }
        }
        proposal.slug = model.uniqueTaskSlug(slugify(proposal.slug), in: scope.id)

        if repos.isEmpty { repos = proposal.repos }
        if repos.isEmpty, model.repoCandidates(in: scope).count == 1 {
            repos = model.repoCandidates(in: scope).map(\.path)
        }
        guard !repos.isEmpty else {
            return .failure(.badRequest("which repository should the task sandbox?",
                                        detail: "Name one with --repo. This scope holds:\n"
                                            + summary.repos.map { "  \($0)" }.joined(separator: "\n")))
        }

        let startPoint = request.startPoint
        let sandboxes = model.env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug)
            .appending(path: proposal.slug, directoryHint: .isDirectory)
        guard !params.dryRun else {
            // Nothing is written: this is the answer an agent shows before asking for the real thing.
            return .success(.task(TaskNewResult(
                created: false, name: proposal.title, slug: proposal.slug, branch: proposal.branch,
                scope: summary.name, scopeSlug: summary.slug, root: sandboxes.path,
                repos: repos.map { TaskRepoResult(repo: $0, worktree: sandboxes.appending(path: $0).path,
                                                  branch: proposal.branch,
                                                  branchCreated: startPoint.requiredBranch == nil) }
            )))
        }

        let parent: String? = if case .thread(let id, _) = origin { id.rawValue } else { nil }
        let threadOrigin = ThreadOrigin(author: .control, parent: parent,
                                        depth: AutomationPolicy.childDepth(of: origin), client: caller.client)
        let state: TaskState
        do {
            state = try await model.createTask(proposal, prompt: prompt, driverID: params.driver, in: scope.id,
                                               repos: repos, startPoint: startPoint, openThread: params.openThread,
                                               runSetup: params.runSetup, threadOrigin: threadOrigin, createdBy: caller.client)
        } catch {
            return .failure(.failed("Scope could not create the task", detail: String(describing: error)))
        }
        NSApp.requestUserAttention(.informationalRequest)
        let record = state.record
        return .success(.task(TaskNewResult(
            created: true, task: record.id.rawValue, name: record.name, slug: record.slug, branch: record.branch,
            scope: summary.name, scopeSlug: summary.slug, root: record.root,
            repos: record.repos.map { TaskRepoResult(repo: $0.repoRelativePath, worktree: $0.sandboxPath,
                                                     branch: $0.branch, branchCreated: $0.branchCreated ?? false) },
            thread: model.threads(in: record.id).first?.id.rawValue
        )))
    }

    /// Runs an alert and answers `false` if nobody touched it before `timeout` seconds.
    private static func ask(_ alert: NSAlert, timeout: Int) async -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            // No window to hang a sheet on — likely now that `scope mcp` is reached from sessions outside Scope while
            // the window is closed. A modal run, bounded like the sheet: a timer in the modal run loop's own mode
            // aborts it, which reads as a refusal instead of holding the caller and the main thread forever.
            let timer = Timer(timeInterval: TimeInterval(timeout), repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            NSApp.activate()
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
