import AppKit
import Foundation
import ScopeControl
import ScopeCore
import ScopeDrivers
import ScopeGit
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

    let reservations = AutomationReservations()

    /// Every scope together: the budgets guard the machine, and a loop does not stay in one scope.
    var agentLoad: AutomationLoad {
        AutomationLoad(
            tasks: model.tasks.filter { !$0.isArchived && $0.record.createdByAgent }.count,
            threads: model.threads.filter { $0.isAlive && $0.record.resolvedOrigin.openedByAgent }.count
        )
    }

    /// The confirmation on screen, then the ones waiting behind it.
    private var confirmations: Task<Bool, Never>?
    private var waitingConfirmations = 0
    /// Past this many questions waiting their turn, a request is refused outright: a burst of approvals from one
    /// loop is a sign to stop it, not a queue to work through.
    private static let maxWaitingConfirmations = 3

    /// A `SCOPE_THREAD` is only worth something when it names a thread this app is running: the variable
    /// lives in a process the user owns and anything under that account can write it.
    func origin(for caller: ControlCaller) -> ControlOrigin {
        AutomationPolicy.origin(of: caller) { [model] id in model.session(id)?.record.resolvedOrigin.depth }
    }

    /// One question at a time: a burst of agents asking at once used to stack sheets whose deadlines all ran from
    /// the moment they were asked. Each still answers within the approval timeout of its own request — the caller
    /// is waiting — so one that never reached the screen in time is refused.
    func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool {
        guard waitingConfirmations < Self.maxWaitingConfirmations else { return false }
        let deadline = Date.now.addingTimeInterval(TimeInterval(automation.approvalTimeout))
        let previous = confirmations
        waitingConfirmations += 1
        let turn = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            self?.waitingConfirmations -= 1
            let remaining = Int(deadline.timeIntervalSinceNow.rounded(.down))
            guard let self, remaining >= 5 else { return false }
            return await self.present(subject, from: origin, caller: caller, timeout: remaining)
        }
        confirmations = turn
        return await turn.value
    }

    private func present(_ subject: String, from origin: ControlOrigin, caller: ControlCaller, timeout: Int) async -> Bool {
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
        return await AppControlService.ask(alert, timeout: timeout)
    }

    func perform(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller,
                 progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
        noteControlCall(call, from: origin, caller: caller)
        switch call {
        case .ping:
            return .success(.ping(PingResult(app: BuildFlavor.displayName, version: model.env.appVersion,
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
                if let role = session.record.resident {
                    return .failure(.failed("thread \(session.id.rawValue) is the \(role.rawValue) of its scope: Scope keeps it "
                                            + "while the scope is declared. Stop it instead (`scope thread stop`); it stays "
                                            + "stopped until someone relaunches it or Scope opens again."))
                }
                // Asked for explicitly: no "close a running thread?" sheet for the caller to wait on.
                _ = await model.close(session.id, force: true)
                return .success(.action(ActionResult(message: "closed \(session.id.rawValue) — \(session.title)",
                                                     thread: session.id.rawValue), .threadClose))
            }
        case .threadSend(var params):
            // A driver command rewrites how another agent works and carries no signature: its own, narrower reach.
            let reach = params.command ? automation.effectiveCommandReach : automation.threadReach
            params.text = await model.expandMentions(params.text)
            let sent = act(on: params.thread, from: origin, reach: reach) { session in
                guard session.isAlive else {
                    // A scope's residents start on its first visit; a message is a good reason to start one sooner.
                    if session.record.resident != nil, model.residentHolds[session.id] == nil {
                        model.startResidents(in: session.record.scopeID)
                        return .failure(.failed("thread \(session.id.rawValue) was not running; Scope is starting it. "
                                                + "Send again once `scope thread wait \(session.id.rawValue)` returns."))
                    }
                    return .failure(.failed("thread \(session.id.rawValue) is not running"))
                }
                // A message from an agent says who sent it; keystrokes (no ↩), a driver command and the user's own
                // typing go as they are.
                let sender = params.submit && !params.command ? sender(of: origin, caller: caller, to: session) : nil
                let text = sender.map { ThreadMessage.envelope(params.text, from: $0) } ?? params.text
                if params.submit { session.submit(text) } else { session.send(text) }
                let signed = sender.map { ", signed as \($0.thread?.id ?? $0.client)" } ?? ""
                let what = params.command ? "sent the command \(params.text.prefix(40)) to" : "typed \(params.text.count) characters into"
                return .success(.action(ActionResult(message: "\(what) \(session.id.rawValue)"
                                                         + (params.submit ? " and pressed ↩" : "") + signed,
                                                     thread: session.id.rawValue), .threadSend))
            }
            // `--wait`: the same wait a second call would have made, its answer carried with the send's. A wait that
            // fails (the reach for reading is narrower than for typing) leaves the send reported as it was.
            guard let waitParams = params.waitParams, case .success(.action(var action, let method)) = sent else { return sent }
            switch await wait(waitParams, from: origin) {
            case .success(.wait(let result)): action.wait = result
            case .failure(let error): action.message += "\n(not waited for: \(error.message))"
            default: break
            }
            return .success(.action(action, method))
        case .threadRead(let params):
            // The gate is `thread.send`'s: the same reach, and any thread from the user's own terminal.
            return act(on: params.thread, from: origin) { session in
                let transcript = TerminalBridge.transcript(of: session)
                let page = ThreadTranscript.page(transcript.lines, firstLineNumber: transcript.firstLineNumber,
                                                 count: params.lines, cursor: params.cursor)
                let state = session.displayState.name
                guard params.view == .reply else {
                    return .success(.read(ThreadReadResult(thread: session.id.rawValue, title: session.title,
                                                           state: state, page: page)))
                }
                guard let reply = session.lastReply else {
                    let why = session.deliversEvents
                        ? "no turn has ended since Scope started this thread"
                        : "\(session.profile.name) does not report its answers"
                    return .success(.read(ThreadReadResult(thread: session.id.rawValue, title: session.title, state: state,
                                                           page: page, note: "no reply to show (\(why)); its terminal instead:")))
                }
                return .success(.read(ThreadReadResult(thread: session.id.rawValue, title: session.title, state: state,
                                                       reply: reply, terminalEnd: page.toLine,
                                                       lastPromptAt: session.lastPromptAt)))
            }
        case .threadWait(let params):
            return await wait(params, from: origin)
        case .summary(let params):
            return await summary(params)
        case .taskShow(let params):
            return await show(params)
        case .configGet(let params):
            return ConfigKey.get(params, in: automation)
        case .configSet(let params):
            // The policy already turned agents away; this is the user, applied the way Settings ▸ Automation does.
            return ConfigKey.set(params, in: automation).map { change in
                model.updatePreferences { $0.automation = change.settings }
                return change.answer
            }
        case .usage(let params):
            return await model.usageReport(params)
        case .taskClose(let params):
            return await dismantle(params.task, scope: params.scope, .close(deleteBranch: params.deleteBranch), method: .taskClose,
                                   from: origin, caller: caller,
                                   done: "closed the task %@" + (params.deleteBranch ? " and deleted its branch" : "; its branch is kept"))
        case .taskArchive(let params):
            return await dismantle(params.task, scope: params.scope, .archive, method: .taskArchive, from: origin, caller: caller,
                                   done: "archived the task %@; its branch is kept")
        case .taskTopic(let params):
            return await fileTask(params, from: origin)
        case .taskRestore(let params):
            return await restore(params, from: origin, caller: caller)
        case .taskRebase(let params):
            return await rebase(params, from: origin, caller: caller)
        case .taskTry(let params):
            return await tryInCheckout(params, from: origin, caller: caller)
        case .release(let params):
            return await release(params, from: origin, caller: caller, progress: progress)
        case .taskCheckpoints(let params):
            return await checkpoints(params, from: origin, caller: caller)
        case .taskRestoreCheckpoint(let params):
            return await restoreCheckpoint(params, from: origin, caller: caller)
        case .gc(let params):
            guard let report = await model.collectGarbage(dryRun: params.dryRun, force: true) else {
                return .failure(.failed("the cleanup did not run"))
            }
            return .success(.action(ActionResult(message: Self.describe(report, dryRun: params.dryRun)), .gc))
        case .scheduleList(let params):
            return listSchedules(params, from: origin, caller: caller)
        case .scheduleRun(let params):
            return runSchedule(params, from: origin, caller: caller)
        case .milestoneAdd(let params):
            return await addMilestone(params, from: origin, caller: caller)
        case .milestoneDone(let params):
            return await markMilestoneDone(params, from: origin, caller: caller)
        case .taskBranchAdd(let params):
            return await addBranch(params, from: origin, caller: caller)
        case .taskBranchList(let params):
            return listBranches(params, from: origin, caller: caller)
        case .taskBranchRemove(let params):
            return await removeBranch(params, from: origin, caller: caller)
        }
    }

    // MARK: Several branches

    /// `task.branch.add`: `AppModel.addBranch` on the task named, or the caller's own. `from` names an existing
    /// branch, `pr` a pull request whose head is checked out (resolved through `gh`, as a task's start point is).
    private func addBranch(_ params: TaskBranchAddParams, from origin: ControlOrigin,
                           caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTaskOrOwn(params.task, scope: params.scope, from: origin, caller: caller, verb: "add a branch to") {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let slug = task.record.slug
        guard !task.isArchived else {
            return .failure(.badRequest("\(slug) is archived", detail: "Restore it first: `scope task restore \(slug)`."))
        }
        let branch = params.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return .failure(.badRequest("say which branch to add")) }
        if let from = params.from, let pr = params.pr, !from.isEmpty, !pr.isEmpty {
            return .failure(.badRequest("task.branch.add takes from or pr, not both"))
        }
        var startPoint: TaskStartPoint = .defaultBranch
        if let from = params.from?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty {
            startPoint = .existingBranch(from)
        } else if let raw = params.pr?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let reference = PullRequestReference.parse(raw) else {
                return .failure(.badRequest("“\(raw)” is not a pull request reference", detail: "Use 123, #123, owner/repo#123 or the URL."))
            }
            let repos = params.repo.map { [$0] } ?? task.activeRepos.map(\.repoRelativePath)
            let resolved = await model.resolveTaskRequest(prompt: "", in: task.scopeID, startPR: reference, repos: repos)
            guard let pr = resolved.pullRequest else {
                return .failure(.notFound(resolved.unresolved ?? "\(reference.label) could not be resolved"))
            }
            startPoint = .pullRequest(pr)
        }
        do {
            let record = try await model.addBranch(branch, to: task.id, repo: params.repo, startPoint: startPoint)
            let name = startPoint.requiredBranch ?? branch
            guard let added = record.activeSandboxes.last(where: { $0.isSecondary && $0.branch == name }) else {
                return .failure(.failed("the worktree on \(name) was not recorded"))
            }
            let line = "added \(name) to \(slug): worktree \(added.sandboxPath)"
                + "\nscope thread new --task \(slug) --branch \(name) opens a thread in it"
            return .success(.action(ActionResult(message: line, task: task.record.id.rawValue), .taskBranchAdd))
        } catch {
            return .failure(.failed("could not add \(branch) to \(slug)", detail: String(describing: error)))
        }
    }

    /// `task.branch.list`: every worktree of the task, with the pull requests Scope last saw on each branch.
    private func listBranches(_ params: TaskBranchListParams, from origin: ControlOrigin,
                              caller: ControlCaller) -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTaskOrOwn(params.task, scope: params.scope, from: origin, caller: caller, verb: "list the branches of") {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let summaries = pullRequestSummaries(for: task)
        let entries = task.record.sandboxes.map { sandbox in
            let prs = task.record.pullRequests.filter { $0.headRefName == sandbox.branch && ($0.repo ?? sandbox.repoRelativePath) == sandbox.repoRelativePath }
                .compactMap { link in summaries.first { $0.url == link.url } }
            return TaskBranchListResult.Entry(
                repo: sandbox.repoRelativePath, branch: sandbox.branch, worktree: sandbox.sandboxPath, primary: !sandbox.isSecondary,
                base: task.record.repo(at: sandbox.repoRelativePath)?.worktree(onBranch: sandbox.branch)?.base,
                pullRequests: prs.isEmpty ? nil : prs
            )
        }
        return .success(.taskBranches(TaskBranchListResult(task: task.record.id.rawValue, slug: task.record.slug, worktrees: entries)))
    }

    /// `task.branch.remove`: `AppModel.removeBranch`, the notice's lines in the answer.
    private func removeBranch(_ params: TaskBranchRemoveParams, from origin: ControlOrigin,
                              caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTaskOrOwn(params.task, scope: params.scope, from: origin, caller: caller, verb: "remove a branch from") {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let slug = task.record.slug
        guard !task.isArchived else {
            return .failure(.badRequest("\(slug) is archived", detail: "Its worktrees are already gone; `scope task restore \(slug)` brings them back."))
        }
        do {
            let notices = try await model.removeBranch(params.branch, from: task.id, repo: params.repo)
            var lines = ["removed the worktree on \(params.branch) from \(slug); the branch is kept"]
            for notice in notices {
                if case .changesSaved(let repo, let ref, let skipped) = notice {
                    lines.append("\(repo): uncommitted changes saved under \(ref)"
                                 + (skipped.isEmpty ? "" : " (too big to keep: \(skipped.joined(separator: ", ")))"))
                }
            }
            return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: task.record.id.rawValue), .taskBranchRemove))
        } catch {
            return .failure(.failed("could not remove \(params.branch) from \(slug)", detail: String(describing: error)))
        }
    }

    // MARK: Schedules

    private func callerScopeID(_ origin: ControlOrigin) -> String? {
        if case .thread(let id, _) = origin { return model.session(id)?.record.scopeID.rawValue }
        return nil
    }

    private func resolveScope(_ query: String?, from origin: ControlOrigin, caller: ControlCaller) -> Result<ScopeID?, ControlError> {
        guard let query else { return .success(nil) }
        let resolved = ScopeResolver.resolve(query, in: scopeSummaries, callerScopeID: callerScopeID(origin), callerCwd: caller.cwd)
        guard case .success(let summary) = resolved else { return .failure(resolved.failureError) }
        return .success(ScopeID(rawValue: summary.id))
    }

    private func listSchedules(_ params: ScheduleListParams, from origin: ControlOrigin,
                               caller: ControlCaller) -> Result<ControlResultPayload, ControlError> {
        switch resolveScope(params.scope, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let scopeID): return .success(.schedules(ScheduleListResult(schedules: model.scheduleSummaries(in: scopeID))))
        }
    }

    /// `schedule.run`: fires now and answers with what went out; the reply lands in the Inbox, not here.
    private func runSchedule(_ params: ScheduleRunParams, from origin: ControlOrigin,
                             caller: ControlCaller) -> Result<ControlResultPayload, ControlError> {
        let scopeID: ScopeID?
        switch resolveScope(params.scope, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let found): scopeID = found
        }
        let schedule: Schedule
        let home: ScopeID
        switch model.findSchedule(params.name, in: scopeID) {
        case .failure(let error): return .failure(error)
        case .success(let found): (schedule, home) = found
        }
        guard let run = model.fireSchedule(schedule, in: home) else {
            return .failure(.failed("the schedule “\(schedule.name)” is already running",
                                    detail: "Its reply will land in the Inbox; `scope thread wait` on its thread to read it sooner."))
        }
        guard run.outcome != .failed else { return .failure(.failed("the schedule “\(schedule.name)” did not run", detail: run.summary)) }
        let where_ = switch schedule.target.kind {
        case .orchestrator: "sent to the \(model.scope(home)?.name ?? "scope") orchestrator" + (run.thread.map { " (thread \($0))" } ?? "")
        case .newTask: "opening a task"
        }
        return .success(.action(ActionResult(message: "fired “\(schedule.name)”: \(where_); the reply lands in the Inbox",
                                             thread: run.thread, task: run.task), .scheduleRun))
    }

    // MARK: Missions

    /// The mission a milestone call is about, and whether the caller may touch it: the named task's mission, or the
    /// caller's own; an agent must work in that mission or in one of its tasks.
    private func mission(_ named: String?, from origin: ControlOrigin, caller: ControlCaller) -> Result<(mission: TaskState, own: TaskState?), ControlError> {
        let own: TaskState? = if case .thread(let id, _) = origin {
            model.session(id)?.record.taskID.flatMap { raw in model.tasks.first { $0.record.id.rawValue == raw } }
        } else { nil }
        let subject: TaskState
        if let named {
            switch resolveTask(named, scope: nil, callerScopeID: callerScopeID(origin), callerCwd: caller.cwd) {
            case .failure(let error): return .failure(error)
            case .success(let found): subject = found
            }
        } else if let own {
            subject = own
        } else {
            return .failure(.badRequest("which mission?", detail: "You are not in a task: name one by id or slug (`scope list tasks`)."))
        }
        guard let mission = model.mission(of: subject) else {
            return .failure(.badRequest("\(subject.record.slug) is not a mission and belongs to none",
                                        detail: "A mission is a task created with --mission (mission: true)."))
        }
        if origin.isAgent, let own, model.mission(of: own)?.id != mission.id {
            return .failure(.denied("an agent may only mark milestones of the mission it works in",
                                    detail: "You work in \(own.record.slug); the mission is \(mission.record.slug)."))
        }
        return .success((mission, own))
    }

    private func childTask(_ named: String?, own: TaskState?, mission: TaskState, from origin: ControlOrigin,
                           caller: ControlCaller) -> Result<TaskID?, ControlError> {
        guard let named else {
            // From a child task, the caller is the child.
            return .success(own.flatMap { $0.id == mission.id ? nil : $0.id })
        }
        switch resolveTask(named, scope: nil, callerScopeID: callerScopeID(origin), callerCwd: caller.cwd) {
        case .failure(let error): return .failure(error)
        case .success(let found): return .success(found.id)
        }
    }

    private func addMilestone(_ params: MilestoneAddParams, from origin: ControlOrigin,
                              caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let mission: TaskState, own: TaskState?
        switch self.mission(params.task, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let found): (mission, own) = found
        }
        let child: TaskID?
        switch childTask(params.child, own: own, mission: mission, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let found): child = found
        }
        switch await model.addMilestone(to: mission, title: params.title, validation: params.validation, child: child) {
        case .failure(let error): return .failure(error)
        case .success(let milestone):
            let number = mission.record.mission?.milestones.count ?? 0
            var message = "added milestone \(number) “\(milestone.title)” to \(mission.record.slug)"
            message += milestone.validation.map { " — validated by `\($0)`" } ?? " — no validation: done is enough"
            message += "\n\(mission.record.mission?.caption ?? "")"
            return .success(.action(ActionResult(message: message, task: mission.record.id.rawValue), .milestoneAdd))
        }
    }

    private func markMilestoneDone(_ params: MilestoneDoneParams, from origin: ControlOrigin,
                                   caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let mission: TaskState, own: TaskState?
        switch self.mission(params.task, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let found): (mission, own) = found
        }
        let child: TaskID?
        switch childTask(params.child, own: own, mission: mission, from: origin, caller: caller) {
        case .failure(let error): return .failure(error)
        case .success(let found): child = found
        }
        switch await model.markMilestoneDone(mission, reference: params.milestone, child: child) {
        case .failure(let error): return .failure(error)
        case .success(let milestone):
            var lines: [String]
            switch milestone.state {
            case .validated:
                lines = ["validated “\(milestone.title)” (\(milestone.exit ?? "exit 0"))"]
            case .failed:
                lines = ["the validation of “\(milestone.title)” failed (\(milestone.exit ?? "failed")); its log went to the milestone's thread"]
                if let log = milestone.log { lines.append(log) }
            case .done:
                lines = ["marked “\(milestone.title)” done; nothing to validate"]
            case .open:
                lines = ["“\(milestone.title)” is open"]
            }
            let record = model.task(mission.id)?.record.mission ?? mission.record.mission
            lines.append(record?.caption ?? "")
            if let next = record?.next, milestone.state.isComplete {
                lines.append("next milestone: \(next.title)")
            } else if milestone.state.isComplete {
                lines.append("every milestone is reached: report on the mission")
            }
            return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: mission.record.id.rawValue), .milestoneDone))
        }
    }

    /// Polls rather than observes: twice a second on a handful of threads costs nothing, and a wait cannot miss a
    /// state that came and went between two observations — the expectation is cleared only by the driver's report.
    private func wait(_ params: ThreadWaitParams, from origin: ControlOrigin) async -> Result<ControlResultPayload, ControlError> {
        var sessions: [ThreadSession] = []
        for raw in params.threads where !sessions.contains(where: { $0.id.rawValue == raw }) {
            switch target(raw, from: origin) {
            case .failure(let error): return .failure(error)
            case .success(let session): sessions.append(session)
            }
        }
        let started = Date.now
        let deadline = started.addingTimeInterval(TimeInterval(params.effectiveTimeout))
        // An agent is blocked on this answer: without it, App Nap stretches the half-second tick of a background app
        // into minutes.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "thread.wait")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        func look() -> [Bool] {
            sessions.forEach { $0.settleOutlivedTurn() }
            return sessions.map { ThreadWait.isSettled($0.waitSnapshot, now: .now, waitingSince: started) }
        }
        var settled = look()
        while !ThreadWait.isOver(settled, until: params.until), Date.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            settled = look()
        }
        // A settled thread's next question is where its pull request stands: asked of GitHub now, once per task,
        // unless the background pass just did, so the answer spares the caller a `gh pr view` of its own.
        var refreshed: Set<TaskID> = []
        for (session, done) in zip(sessions, settled) where done {
            guard let task = taskOf(session), !task.isArchived, !refreshed.contains(task.id) else { continue }
            refreshed.insert(task.id)
            let checkedAt = model.pullRequestCheckedAt(for: task)
            guard checkedAt.map({ Date.now.timeIntervalSince($0) > AppControlService.pullRequestFreshness }) ?? true else { continue }
            await model.refreshTaskPullRequest(task)
        }
        let entries = zip(sessions, settled).map { session, settled in
            let task = taskOf(session)
            return ThreadWaitResult.Entry(thread: session.id.rawValue, title: session.title, state: session.displayState.name,
                                          settled: settled, reply: session.lastReply, lastPromptAt: session.lastPromptAt,
                                          agents: session.waitSnapshot.agents, task: task?.record.id.rawValue,
                                          pullRequest: task.flatMap(pullRequestSummary))
        }
        return .success(.wait(ThreadWaitResult(threads: entries, complete: ThreadWait.isOver(settled, until: params.until),
                                               waited: Int(Date.now.timeIntervalSince(started).rounded()))))
    }

    /// A pull request looked at within this many seconds is not asked about again when a wait ends.
    static let pullRequestFreshness: TimeInterval = 30

    /// The task a thread runs in, when it does.
    private func taskOf(_ session: ThreadSession) -> TaskState? {
        guard let raw = session.record.taskID else { return nil }
        return model.tasks.first { $0.record.id.rawValue == raw }
    }

    /// The task's pull request as the answers carry it: what `gh` last said when Scope asked (checks, mergeability,
    /// review), else what the record kept when it was bound.
    /// The task's primary pull request (`TaskRecord.primaryPullRequest`), as `gh` last saw it.
    private func pullRequestSummary(for task: TaskState) -> PullRequestSummary? {
        task.record.primaryPullRequest.map { pullRequestSummary(for: task, link: $0) }
    }

    /// Every pull request of the task, in its order.
    private func pullRequestSummaries(for task: TaskState) -> [PullRequestSummary] {
        task.record.pullRequests.map { pullRequestSummary(for: task, link: $0) }
    }

    private func pullRequestSummary(for task: TaskState, link: LinkedPullRequest) -> PullRequestSummary {
        if let live = model.livePullRequest(for: task, link: link) {
            return PullRequestSummary(number: live.number, url: live.url, title: live.title, state: live.state.rawValue,
                                      checks: live.checks.rawValue, mergeable: live.mergeable.rawValue,
                                      review: live.reviewDecision.rawValue, draft: live.isDraft,
                                      checkedAt: model.pullRequestCheckedAt(for: task, link: link), repo: link.repo)
        }
        return PullRequestSummary(number: link.number, url: link.url, title: link.title, state: link.state ?? "unknown", repo: link.repo)
    }

    /// The task named by id or slug.
    /// `task.topic`: the label, and the tasks it started that share it. The answer echoes the topic as stored —
    /// trimmed and bounded — so the agent sees what the sidebar shows.
    private func fileTask(_ params: TaskTopicParams, from origin: ControlOrigin) async -> Result<ControlResultPayload, ControlError> {
        let found: Result<TaskState, ControlError>
        if let name = params.task {
            found = resolveTask(name, scope: nil, callerScopeID: callerScopeID(origin), callerCwd: nil)
        } else if case .thread(let id, _) = origin,
                  let raw = model.session(id)?.record.taskID, let own = model.tasks.first(where: { $0.record.id.rawValue == raw }) {
            found = .success(own)
        } else {
            found = .failure(.badRequest("which task?", detail: "You are not in a task: name one by id or slug (`scope list tasks`)."))
        }
        let task: TaskState
        switch found {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let topic = TaskTopic.normalize(params.topic)
        if params.topic != nil, topic == nil {
            return .failure(.badRequest("the topic is empty", detail: "Name one, or clear the task's topic instead."))
        }
        // `scope task topic auth-refresh` meant a task and forgot the topic; filing the caller's work under a slug
        // would scatter it.
        if params.task == nil, let topic,
           let named = model.tasks.first(where: { $0.record.slug == topic || $0.record.id.rawValue == topic }) {
            return .failure(.badRequest("“\(topic)” is a task, not a topic",
                                        detail: "Give both: `scope task topic \(named.record.slug) \"<topic>\"`, or --clear to take it out."))
        }
        let slug = task.record.slug
        let changed: [TaskRecord]
        do {
            changed = try await model.refile([task.id], underTopic: topic, withChildren: params.children)
        } catch {
            return .failure(.failed("could not change the topic of \(slug)", detail: String(describing: error)))
        }
        var lines: [String]
        if !changed.contains(where: { $0.id == task.id }) {
            lines = [topic.map { "\(slug) is already under “\($0)”" } ?? "\(slug) has no topic"]
        } else {
            lines = [topic.map { "filed \(slug) under “\($0)”" } ?? "took \(slug) out of its topic"]
        }
        let followers = changed.filter { $0.id != task.id }.map(\.slug)
        if !followers.isEmpty { lines.append("along with the tasks it started: " + followers.joined(separator: ", ")) }
        return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: task.record.id.rawValue), .taskTopic))
    }

    /// `task.restore`: the Restore of an archive notice (`AppModel.restoreTask`), the user's selection left alone.
    private func restore(_ params: TaskRestoreParams, from origin: ControlOrigin,
                         caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        let task: TaskState
        switch resolveTask(params.task, scope: params.scope, callerScopeID: callerScopeID, callerCwd: caller.cwd, preferring: .archived) {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let slug = task.record.slug
        // First: an archive that stopped halfway has no `archivedAt` yet, and its sandboxes may be gone already. The
        // task manager would hand the record back as it is; say why instead of reporting a restore that did nothing.
        guard task.record.cleanup == nil, !task.isDismantling else {
            return .failure(.failed("\(slug) is still being archived",
                                    detail: "Its last archive did not finish. `scope task archive \(slug)` runs it again; restore it after."))
        }
        guard task.record.isArchived else {
            return .failure(.badRequest("\(slug) is not archived", detail: "It is open already: `scope list tasks` shows its sandboxes."))
        }
        // Read before: the restore clears them.
        let salvaged = task.record.repos.filter { $0.salvageRef != nil }.map(\.repoRelativePath)
        do {
            try await model.restoreTask(task.id)
        } catch {
            return .failure(.failed("could not restore the task \(slug)", detail: String(describing: error)))
        }
        var lines = ["restored the task \(slug) on its branch \(task.branch)"]
        for repo in salvaged {
            lines.append("\(repo.isEmpty ? "." : repo): uncommitted changes saved at archive put back")
        }
        lines.append("no thread was opened: `scope thread new --task \(slug)` starts one")
        return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: task.record.id.rawValue), .taskRestore))
    }

    /// `task.rebase`: the clean rebase or the message to the thread, on demand (`AppModel.rebaseNow`). Without a task,
    /// the caller's own.
    private func rebase(_ params: TaskRebaseParams, from origin: ControlOrigin,
                        caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        let task: TaskState
        if let query = params.task {
            switch resolveTask(query, scope: params.scope, callerScopeID: callerScopeID, callerCwd: caller.cwd) {
            case .failure(let error): return .failure(error)
            case .success(let match): task = match
            }
        } else {
            guard case .thread(let id, _) = origin, let own = model.session(id).flatMap(model.task(of:)) else {
                return .failure(.badRequest("say which task to rebase", detail: "`scope list tasks` shows them; from a task's thread the task may be omitted."))
            }
            task = own
        }
        guard !task.isArchived else {
            return .failure(.badRequest("\(task.record.slug) is archived", detail: "Restore it first: `scope task restore \(task.record.slug)`."))
        }
        if task.record.holdBranch {
            return .failure(.denied("the branch of \(task.record.slug) is held",
                                    detail: "The user asked for no automatic rebase on this task (Don't rebase automatically)."))
        }
        let line = await model.rebaseNow(task)
        return .success(.action(ActionResult(message: line, task: task.record.id.rawValue), .taskRebase))
    }

    /// `task.try`: the user's own checkout on the task's branch, refreshed, or put back (`AppModel+TryInCheckout`). The
    /// policy refused every agent already; the check here is the belt to its braces, since the base is the user's.
    private func tryInCheckout(_ params: TaskTryParams, from origin: ControlOrigin,
                               caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        guard case .user = origin else {
            return .failure(.denied("only the user may try a task in their checkout"))
        }
        let task: TaskState
        switch resolveTask(params.task, scope: params.scope, callerScopeID: nil, callerCwd: caller.cwd) {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        do {
            let line: String
            if params.end {
                line = try await model.putBack(task)
            } else if params.refresh {
                line = try await model.refreshTry(task)
            } else {
                line = try await model.tryInCheckout(task)
            }
            return .success(.action(ActionResult(message: line, task: task.record.id.rawValue), .taskTry))
        } catch let failure as TryInCheckoutFailure {
            switch failure {
            case .notAllowed: return .failure(.denied(String(describing: failure), detail: "Turn it on in Settings › Tasks, or set allowTryInCheckout on the scope in config.json."))
            default: return .failure(.badRequest(String(describing: failure)))
            }
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    /// `release`: the repository resolved from what the caller said or where it runs, then `ReleaseRunner` in the
    /// app's own processes — the user's login-shell environment, no `SCOPE_*`, no sandbox hooks — in a clone under
    /// `<home>/releases/`. The script's lines come back as progress while it runs, and in the answer.
    private func release(_ params: ReleaseParams, from origin: ControlOrigin, caller: ControlCaller,
                         progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
        let session: ThreadSession? = if case .thread(let id, _) = origin { model.session(id) } else { nil }
        let summary: ScopeSummary
        switch ScopeResolver.resolve(params.scope, in: scopeSummaries, callerScopeID: session?.record.scopeID.rawValue,
                                     callerCwd: caller.cwd) {
        case .failure(let error): return .failure(error)
        case .success(let found): summary = found
        }
        guard let scope = model.scopes.first(where: { $0.id.rawValue == summary.id }) else {
            return .failure(.notFound("no scope “\(summary.slug)”"))
        }
        let relativePath: String
        switch releaseRepo(params.repo, in: summary, task: session.flatMap(model.task(of:)), cwd: caller.cwd) {
        case .failure(let error): return .failure(error)
        case .success(let path): relativePath = path
        }
        guard let repo = scope.repo(relativePath: relativePath) else {
            return .failure(.notFound("no repository “\(relativePath)” in \(summary.slug)", detail: summary.repos.joined(separator: "\n")))
        }
        var facts = repo.facts
        if facts?.originURL == nil {
            facts = await RepoFacts.load(for: repo.url, using: await model.env.git.client(for: repo.url))
        }
        guard let originURL = facts?.originURL, !originURL.isEmpty else {
            return .failure(.failed("\(repo.displayName) has no origin remote", detail: "A release is cut from a clone of origin's default branch."))
        }
        let name = facts?.remote?.fullName.replacingOccurrences(of: "/", with: "-") ?? repo.url.lastPathComponent
        let target = ReleaseTarget(repo: relativePath.isEmpty ? "." : relativePath, scopeSlug: summary.slug,
                                   originURL: originURL, name: name)
        let shell = await model.env.shell.environment()
        let runner = ReleaseRunner(
            home: model.env.home, gitPath: model.env.git.gitPath,
            ghPath: ExecutableResolver.resolve("gh", path: shell.path, shell: shell.shell) ?? GhClient.locate(environment: shell.variables)?.executable,
            cliffPath: ExecutableResolver.resolve("git-cliff", path: shell.path, shell: shell.shell),
            environment: SandboxGitHooks.withoutInheritedThread(shell.variables), runner: ProcessReleaseRunner()
        )
        // An agent is waiting on the answer, and the clone and the script take minutes a napping app would stretch.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "release")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return await runner.release(target, params: params, progress: progress).map { .release($0) }
    }

    /// Which repository `scope release` means: the one named, else the task's only one, else the one whose sandbox or
    /// base checkout holds the caller's cwd, else the scope's only one.
    private func releaseRepo(_ query: String?, in scope: ScopeSummary, task: TaskState?, cwd: String?) -> Result<String, ControlError> {
        if let query {
            return ScopeResolver.resolveRepo(query, in: scope).map { $0 == "." ? "" : $0 }
        }
        func normalized(_ path: String) -> String { path == "." ? "" : path }
        let active = task?.record.repos.filter { $0.state == .active } ?? []
        if active.count == 1 { return .success(normalized(active[0].repoRelativePath)) }
        if let cwd {
            let standardized = (cwd as NSString).standardizingPath
            if let inSandbox = active.first(where: { standardized == $0.sandboxPath || standardized.hasPrefix($0.sandboxPath + "/") }) {
                return .success(normalized(inSandbox.repoRelativePath))
            }
            let root = (scope.path as NSString).standardizingPath
            let inBase = scope.repos
                .filter { path in
                    let base = path.isEmpty ? root : root + "/" + path
                    return standardized == base || standardized.hasPrefix(base + "/")
                }
                .max { $0.count < $1.count }
            if let inBase { return .success(inBase) }
        }
        if scope.repos.count == 1 { return .success(scope.repos[0]) }
        return .failure(.badRequest("which repository?",
                                    detail: "Name one with --repo:\n" + scope.repos.map { "  \($0.isEmpty ? "." : $0)" }.joined(separator: "\n")))
    }

    /// The task `query` names, or — without one — the task the caller's thread runs in.
    private func resolveTaskOrOwn(_ query: String?, scope: String?, from origin: ControlOrigin, caller: ControlCaller,
                                  verb: String) -> Result<TaskState, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        if let query { return resolveTask(query, scope: scope, callerScopeID: callerScopeID, callerCwd: caller.cwd) }
        guard case .thread(let id, _) = origin, let own = model.session(id).flatMap(model.task(of:)) else {
            return .failure(.badRequest("say which task to \(verb)", detail: "`scope list tasks` shows them; from a task's thread the task may be omitted."))
        }
        return .success(own)
    }

    /// `task.checkpoints`: the list, as the Task section shows it.
    private func checkpoints(_ params: TaskCheckpointsParams, from origin: ControlOrigin,
                             caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTaskOrOwn(params.task, scope: params.scope, from: origin, caller: caller, verb: "list the checkpoints of") {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let entries = await model.env.tasks.checkpoints.list(task.id).map { checkpoint in
            TaskCheckpointsResult.Entry(
                number: checkpoint.number, at: checkpoint.at, reason: checkpoint.reason == .turn ? "turn" : "before_restore",
                thread: checkpoint.threadID, threadTitle: checkpoint.threadTitle, turn: checkpoint.turn, said: checkpoint.said,
                additions: checkpoint.additions, deletions: checkpoint.deletions, repos: checkpoint.repos.map(\.repoRelativePath)
            )
        }
        return .success(.taskCheckpoints(TaskCheckpointsResult(task: task.record.id.rawValue, slug: task.record.slug, checkpoints: entries)))
    }

    /// `task.restore-checkpoint`: the Restore files of the Task section (`AppModel.restoreCheckpoint`). An agent may
    /// restore within its own task only; the user anywhere.
    private func restoreCheckpoint(_ params: TaskRestoreCheckpointParams, from origin: ControlOrigin,
                                   caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTaskOrOwn(params.task, scope: params.scope, from: origin, caller: caller, verb: "restore a checkpoint of") {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let slug = task.record.slug
        guard !task.isArchived else {
            return .failure(.badRequest("\(slug) is archived", detail: "Restore it first: `scope task restore \(slug)`."))
        }
        if let refusal = AutomationPolicy.mayRestoreCheckpoint(of: slug, taskThreads: model.threads(in: task.id).map(\.id), from: origin) {
            return .failure(refusal)
        }
        do {
            let result = try await model.restoreCheckpoint(params.number, of: task)
            var lines = ["restored checkpoint \(params.number) of \(slug): every sandbox has its files; branch, commits and index untouched"]
            if let undo = result.undo {
                lines.append("the files as they were are checkpoint \(undo.number): `scope task restore-checkpoint \(slug) \(undo.number)` undoes this")
            }
            return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: task.record.id.rawValue), .taskRestoreCheckpoint))
        } catch {
            return .failure(.failed("could not restore checkpoint \(params.number) of \(slug)", detail: String(describing: error)))
        }
    }

    /// Archive and close: the task named by id or slug — the live one when an archived namesake of another scope
    /// shares the slug (`TaskLookup`) — and the outcome said in a few lines.
    private func dismantle(_ name: String, scope: String?, _ mode: DismantleMode, method: ControlMethod,
                           from origin: ControlOrigin, caller: ControlCaller, done: String) async -> Result<ControlResultPayload, ControlError> {
        let task: TaskState
        switch resolveTask(name, scope: scope, callerScopeID: callerScopeID(origin), callerCwd: caller.cwd) {
        case .failure(let error): return .failure(error)
        case .success(let match): task = match
        }
        let slug = task.record.slug
        let outcome: DismantleOutcome
        do {
            outcome = try await model.dismantleTask(task.id, mode)
        } catch {
            return .failure(.failed("could not \(mode == .archive ? "archive" : "close") the task \(slug)",
                                    detail: String(describing: error)))
        }
        var lines = [done.replacingOccurrences(of: "%@", with: slug)]
        if !outcome.stoppedProcesses.isEmpty {
            lines.append("stopped: " + outcome.stoppedProcesses.joined(separator: ", "))
        }
        for notice in outcome.notices {
            switch notice {
            case .changesSaved(let repo, let ref, let skipped):
                lines.append("\(repo): uncommitted changes saved as \(ref)"
                             + (skipped.isEmpty ? "" : " — too big to keep: " + skipped.joined(separator: ", ")))
            case .branchSaved(let repo, let branch, let ref): lines.append("\(repo): unmerged \(branch) saved as \(ref)")
            case .teardownFailed(let repo, let summary, _): lines.append("\(repo): teardown failed (\(summary))")
            case .processesSurvived(let names): lines.append("would not stop: " + names.joined(separator: ", "))
            }
        }
        return .success(.action(ActionResult(message: lines.joined(separator: "\n"), task: task.record.id.rawValue), method))
    }

    static func describe(_ report: GarbageReport, dryRun: Bool) -> String {
        if report.skipped { return "a cleanup is already running; try again in a moment" }
        guard !report.isEmpty || (dryRun && !report.sandboxSizes.isEmpty) else { return "nothing to clean" }
        var lines: [String] = []
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append(title)
            lines += items.map { "  \($0)" }
        }
        section(dryRun ? "would remove these folders:" : "removed these folders:", report.removedFolders)
        section("saved their uncommitted work:", report.savedChanges)
        section(dryRun ? "would stop:" : "stopped:", report.stoppedProcesses)
        section("would not stop:", report.survivors)
        section("kept, their work could not be saved:", report.keptFolders)
        section(dryRun ? "would prune stale worktrees in:" : "pruned stale worktrees in:", report.prunedWorktrees)
        section(dryRun ? "would delete expired saved changes:" : "deleted expired saved changes:", report.deletedRefs)
        if report.emptiedTrash > 0 {
            lines.append((dryRun ? "would empty " : "emptied ") + "\(report.emptiedTrash) \(report.emptiedTrash == 1 ? "item" : "items") from the trash")
        }
        if dryRun, !report.sandboxSizes.isEmpty {
            let count = report.sandboxSizes.count
            lines.append("live sandboxes take \(SandboxSize.text(report.sandboxBytes)) across \(count) \(count == 1 ? "task" : "tasks")"
                         + (report.largestSandboxes.isEmpty ? "" : "; the heaviest:"))
            lines += report.largestSandboxes.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// The thread `raw` names, when `origin` may act on it (`AutomationPolicy.mayTouch`) within `reach` — the
    /// general one unless the caller says otherwise.
    private func target(_ raw: String, from origin: ControlOrigin,
                        reach: AutomationSettings.ThreadReach? = nil) -> Result<ThreadSession, ControlError> {
        guard let id = ThreadID(rawValue: raw), let session = model.session(id) else {
            return .failure(.notFound("no thread “\(raw)”", detail: "`scope list threads` shows the ids."))
        }
        if let refusal = AutomationPolicy.mayTouch(session.record.resolvedOrigin, id: session.id, from: origin,
                                                   reach: reach ?? automation.threadReach) {
            return .failure(refusal)
        }
        return .success(session)
    }

    /// Who signs a message typed into `target` — an agent, never the user, whose typing is their own.
    private func sender(of origin: ControlOrigin, caller: ControlCaller, to target: ThreadSession) -> ThreadMessage.Sender? {
        switch origin {
        case .user, .strangerThread:
            return nil
        case .externalAgent(let client):
            return ThreadMessage.Sender(client: client)
        case .thread(let id, _):
            guard let session = model.session(id) else { return ThreadMessage.Sender(client: caller.client) }
            let record = session.record
            let task = record.taskID.flatMap { taskID in model.tasks.first { $0.record.id.rawValue == taskID } }
            let scope = record.scopeID == target.record.scopeID ? nil : model.scope(record.scopeID)?.declaration.slug
            return ThreadMessage.Sender(thread: .init(id: id.rawValue, title: session.title, task: task?.record.slug,
                                                      scope: scope), client: caller.client)
        }
    }

    private func act(on raw: String, from origin: ControlOrigin, reach: AutomationSettings.ThreadReach? = nil,
                     _ body: (ThreadSession) -> Result<ControlResultPayload, ControlError>) -> Result<ControlResultPayload, ControlError> {
        switch target(raw, from: origin, reach: reach) {
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

    /// One line in the usage log per call carried out: the method, who asked (an agent or the user's own terminal) and
    /// through which façade. Never the arguments.
    private func noteControlCall(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller) {
        let client = caller.client.hasPrefix(ControlClientName.mcp) ? "mcp" : caller.client.hasPrefix(ControlClientName.cli) ? "cli" : "other"
        Usage.record(.control, "control.\(call.method.rawValue)", source: origin.isAgent ? .agent : .user, context: client)
    }

    /// Live records and the history of closed ones, handed to `ActivitySummary`. Only reads: a pull request whose state
    /// Scope never saw is reported as unknown rather than looked up here, which would cost a `gh` call per task.
    private func summary(_ params: SummaryParams) async -> Result<ControlResultPayload, ControlError> {
        let timeZone = TimeZone.current
        guard let period = ActivityPeriod.parse(params.period, calendar: ActivityPeriod.calendar(timeZone)) else {
            return .failure(.badRequest("no period called “\(params.period ?? "")”", detail: ActivityPeriod.grammar))
        }
        let scopes = scopeSummaries.map { ActivitySummary.ScopeRef(id: $0.id, slug: $0.slug, name: $0.name, root: $0.path) }
        var tasks: [TaskSnapshot] = []
        for record in await model.env.tasks.allTasks { tasks.append(await model.summarySnapshot(of: record)) }
        let threads = model.threads.map(\.record.snapshot)
        let home = model.env.home
        let (history, deliverables) = await Task.detached { (ActivityHistory.load(home: home), TaskDeliverableStore.loadAll(home: home)) }.value
        let tokens = model.tokenTotalsByThread
        if let name = params.task {
            guard let result = ActivitySummary.detail(of: name, timeZone: timeZone, period: period, scopes: scopes,
                                                      tasks: tasks, threads: threads, history: history, deliverables: deliverables,
                                                      tokens: tokens) else {
                return .failure(.notFound("no task “\(name)”, open, archived or closed since the history began"))
            }
            return .success(.summary(result))
        }
        return .success(.summary(ActivitySummary.build(period: period, timeZone: timeZone, scopes: scopes, tasks: tasks,
                                                       threads: threads, history: history, deliverables: deliverables,
                                                       scopeFilter: params.scope, tokens: tokens)))
    }

    /// `scope task show`: the same snapshots, one task.
    private func show(_ params: TaskShowParams) async -> Result<ControlResultPayload, ControlError> {
        let scopes = scopeSummaries.map { ActivitySummary.ScopeRef(id: $0.id, slug: $0.slug, name: $0.name, root: $0.path) }
        let tasks = await model.env.tasks.allTasks.map(\.snapshot)
        let threads = model.threads.map(\.record.snapshot)
        let home = model.env.home
        let (history, deliverables) = await Task.detached { (ActivityHistory.load(home: home), TaskDeliverableStore.loadAll(home: home)) }.value
        guard var result = ActivitySummary.show(params.task, scopes: scopes, tasks: tasks, threads: threads, history: history,
                                                deliverables: deliverables) else {
            return .failure(.notFound("no task “\(params.task)”, open, archived or closed since the history began"))
        }
        if let task = model.tasks.first(where: { $0.record.id.rawValue == result.task.id }) {
            result.pullRequest = pullRequestSummary(for: task)
            result.pullRequests = pullRequestSummaries(for: task)
        }
        return .success(.taskShow(result))
    }

    private func summary(_ session: ThreadSession) -> ThreadSummary {
        let scope = model.scope(session.record.scopeID)
        let origin = session.record.resolvedOrigin
        return ThreadSummary(
            id: session.id.rawValue, title: session.title, driver: session.record.driverID, model: session.record.model,
            scope: scope?.name ?? session.record.scopeRoot, scopeSlug: scope?.declaration.slug ?? "",
            task: session.record.taskID, cwd: session.record.cwd,
            state: session.displayState.name, alive: session.isAlive,
            openedBy: origin.client ?? origin.author.rawValue, depth: origin.depth, parent: origin.parent,
            resident: session.record.resident?.rawValue,
            activity: session.resumingAfterRestart
                ? InterruptedTurn.activityLine
                : ThreadActivityLine.text(session.activity, cwd: session.record.cwd, now: .now),
            tokens: TokenUsageText.threadField(model.tokenUsage.snapshot.threads[session.id.rawValue])
        )
    }

    private func summary(_ task: TaskState) -> TaskSummary {
        let scope = model.scope(task.scopeID)
        return TaskSummary(
            id: task.record.id.rawValue, name: task.name, slug: task.record.slug, branch: task.branch,
            scope: scope?.name ?? task.record.scopeName, scopeSlug: task.record.scopeSlug,
            root: task.record.root, repos: task.activeRepos.map(\.repoRelativePath),
            threads: model.threads(in: task.record.id).map(\.id.rawValue),
            topic: task.record.topic, parentTask: task.record.parentTask?.rawValue, archivedAt: task.record.archivedAt,
            behind: model.lag(of: task)?.behind, conflicts: model.lag(of: task)?.conflicts,
            holdBranch: task.record.holdBranch ? true : nil,
            pullRequest: pullRequestSummary(for: task), pullRequests: pullRequestSummaries(for: task),
            branches: task.record.branches
        )
    }

    // MARK: Writing

    private func newThread(_ params: ThreadNewParams, from origin: ControlOrigin,
                           caller: ControlCaller) async -> Result<ControlResultPayload, ControlError> {
        let callerScopeID: String? = if case .thread(let id, _) = origin { model.session(id)?.record.scopeID.rawValue } else { nil }
        // A task names its scope: `--task` alone reaches a task of any scope, the caller's when two share a slug.
        var task: TaskState?
        if let query = params.task {
            switch resolveTask(query, scope: params.scope, callerScopeID: callerScopeID, callerCwd: caller.cwd) {
            case .failure(let error): return .failure(error)
            case .success(let found): task = found
            }
        }
        let resolved = ScopeResolver.resolve(task?.scopeID.rawValue ?? params.scope, in: scopeSummaries,
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
        let requestedModel: String?
        switch modelRequested(params.model, driver: params.driver, from: origin) {
        case .failure(let error): return .failure(error)
        case .success(let found): requestedModel = found
        }

        var cwdKind = ThreadCwdKind.scopeRoot
        var taskID: TaskID?
        var branch: String?
        if let task {
            taskID = task.record.id
            if let wanted = params.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
                guard task.record.sandboxes(onBranch: wanted).first != nil else {
                    return .failure(.notFound("\(task.record.slug) has no worktree on \(wanted)",
                                              detail: "Its branches: " + task.record.branches.joined(separator: ", ")
                                                  + ". `scope task branch add \(task.record.slug) \(wanted)` adds one."))
                }
                branch = wanted
            }
        } else if params.branch != nil {
            return .failure(.badRequest("branch needs a task", detail: "The branch is one of that task's worktrees (`scope task branch list`)."))
        } else if let repo = params.repo {
            switch ScopeResolver.resolveRepo(repo, in: scope) {
            case .failure(let error): return .failure(error)
            case .success(let path): cwdKind = .repoBase(relativePath: path == "." ? "" : path)
            }
        }

        let threadOrigin = childOrigin(of: origin, caller: caller)
        var prompt = params.prompt
        if let given = prompt { prompt = await model.expandMentions(given) }
        guard let session = await model.newThread(in: scopeID, driverID: params.driver, cwdKind: cwdKind,
                                                  taskID: taskID, title: params.title, initialPrompt: prompt,
                                                  origin: threadOrigin, model: requestedModel, branch: branch) else {
            return .failure(.failed("Scope could not open the thread",
                                    detail: "The app reported it as a problem; its window says why."))
        }
        // A bounce in the Dock, not a focus steal: an agent opening a thread should be noticed, not obeyed.
        NSApp.requestUserAttention(.informationalRequest)
        return .success(.thread(ThreadNewResult(
            thread: session.id.rawValue, title: session.title, driver: session.record.driverID, model: session.record.model,
            scope: scope.name, scopeSlug: scope.slug, cwd: session.record.cwd,
            task: session.record.taskID, depth: threadOrigin.depth
        )))
    }

    /// The model a request asks for, or the one its caller passes on: a thread's own model reaches the threads it
    /// opens with its own driver (`ModelChoice.inherited`). A model named for a driver that takes none is refused —
    /// silently dropping it would leave the caller believing the thread runs on it.
    private func modelRequested(_ requested: String?, driver: String?,
                                from origin: ControlOrigin) -> Result<String?, ControlError> {
        guard let profile = model.profile(id: driver) else { return .success(nil) }
        if let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty, !profile.acceptsModel {
            return .failure(.badRequest("the driver \(profile.id) takes no model",
                                        detail: "Its profile has no \"modelArgs\". Pick a driver that does, or drop --model."))
        }
        if let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty { return .success(requested) }
        guard case .thread(let id, _) = origin, let caller = model.session(id)?.record else { return .success(nil) }
        return .success(ModelChoice.inherited(callerModel: caller.model, callerDriver: caller.driverID, driver: profile.id))
    }

    /// The task `query` names by id or slug. With `scope`, only in that scope; without, in any scope — the
    /// caller's own when the same slug exists in several.
    /// The task a request names (`TaskLookup`): an id exactly; a slug narrowed by `scope` when given, then to the
    /// kind the command wants (live, or archived for a restore), then to the caller's own scope.
    private func resolveTask(_ query: String, scope: String?, callerScopeID: String?, callerCwd: String?,
                             preferring preference: TaskLookup.Preference = .live) -> Result<TaskState, ControlError> {
        var only: ScopeSummary?
        if let scope {
            let resolved = ScopeResolver.resolve(scope, in: scopeSummaries, callerScopeID: callerScopeID, callerCwd: callerCwd)
            guard case .success(let summary) = resolved else { return .failure(resolved.failureError) }
            only = summary
        }
        let candidates = model.tasks.map { task in
            TaskLookup.Candidate(id: task.record.id.rawValue, slug: task.record.slug, scopeID: task.scopeID.rawValue,
                                 scopeSlug: task.record.scopeSlug, isArchived: task.isArchived)
        }
        switch TaskLookup.resolve(query, among: candidates, preferring: preference, scopeID: only?.id, callerScopeID: callerScopeID) {
        case .found(let match):
            guard let task = model.tasks.first(where: { $0.record.id.rawValue == match.id }) else { return .failure(.notFound("no task “\(query)”")) }
            return .success(task)
        case .ambiguous(let shared):
            return .failure(.badRequest("“\(query)” names a task in several scopes",
                                        detail: "Say which with --scope: " + shared.map(\.qualified).joined(separator: ", ")))
        case .none:
            if let only {
                return .failure(.notFound("no task “\(query)” in \(only.slug)",
                                          detail: model.tasks.filter { $0.scopeID.rawValue == only.id }.map(\.record.slug).joined(separator: ", ")))
            }
            return .failure(.notFound("no task “\(query)”",
                                      detail: "`scope list tasks` shows every task; ids and slugs both work."))
        }
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
        let prompt = await model.expandMentions(params.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !prompt.isEmpty else { return .failure(.badRequest("a task needs a prompt")) }
        // Refused before the proposal, which would otherwise keep the caller waiting for nothing.
        if let branch = params.branch, TaskBranch.isReserved(branch) {
            return .failure(.badRequest(TaskBranch.reservedRefusal(branch)))
        }
        let requestedModel: String?
        switch modelRequested(params.model, driver: params.driver, from: origin) {
        case .failure(let error): return .failure(error)
        case .success(let found): requestedModel = found
        }
        var startPR: PullRequestReference?
        if let raw = params.startPR {
            guard let reference = PullRequestReference.parse(raw) else {
                return .failure(.badRequest("“\(raw)” is not a pull request",
                                            detail: "Give its number (123, #123), owner/repo#123 or its URL."))
            }
            startPR = reference
        }
        var issue: PullRequestReference?
        if let raw = params.issue {
            guard let reference = PullRequestReference.parseIssue(raw) else {
                return .failure(.badRequest("“\(raw)” is not an issue",
                                            detail: "Give its number (123, #123), owner/repo#123 or its URL."))
            }
            guard startPR == nil else { return .failure(.badRequest("a task starts from a pull request or works on an issue, not both")) }
            issue = reference
        }

        var repos: [String] = []
        for query in params.repos {
            switch ScopeResolver.resolveRepo(query, in: summary) {
            case .failure(let error): return .failure(error)
            case .success(let path): repos.append(path)
            }
        }

        // What the prompt is about, before anything is created: the pull request asked for wins over everything.
        var request = await model.resolveTaskRequest(prompt: prompt, in: scope.id, startPR: startPR, issue: issue, repos: repos)
        if let existing = request.existingTask {
            return .failure(.init(.failed, "that pull request already has a task",
                                  detail: "Task \(existing.rawValue) in \(summary.slug)."))
        }
        var note: String?
        if let unresolved = request.unresolved {
            // Asked for by name, it must be there. Read off the prompt, it is Scope's guess: a task on a new branch
            // beats no task over a reference the caller may not even have meant.
            guard startPR == nil else {
                return .failure(.badRequest("the pull request \(params.startPR ?? "") could not be used", detail: unresolved))
            }
            guard issue == nil else {
                return .failure(.badRequest("the issue \(params.issue ?? "") could not be read", detail: unresolved))
            }
            note = TaskNewResult.ignoredReference(request.reference?.label ?? "", reason: request.unresolvedReason ?? unresolved)
            request = .init(repos: request.repos)
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
            // The microsession read an issue the request only alluded to: `gh` says what it is, as for a URL.
            if request.issue == nil, request.pullRequest == nil, let reference = proposal.issue,
               let resolved = await model.resolveProposedIssue(reference, in: scope.id) {
                request.issue = resolved.issue
                if repos.isEmpty { repos = resolved.repos }
            }
            if request.issue != nil, params.title == nil, let issue = request.issue { proposal.title = IssueBrief.title(for: issue) }
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
        // Several attempts: the plan is checked before anything is written, so a bad list refuses cleanly.
        var plans: [TaskAttempts.Plan]?
        if params.attempts > 1 {
            guard startPoint.requiredBranch == nil else {
                return .failure(.badRequest("attempts each need a branch of their own",
                                            detail: "A task that starts from a pull request or an existing branch is one attempt: drop --attempts, or --pr."))
            }
            switch TaskAttempts.plan(count: params.attempts, name: proposal.title, slug: proposal.slug, branch: proposal.branch,
                                     models: params.models, drivers: params.drivers) {
            case .failure(let refusal): return .failure(.badRequest(refusal.message))
            case .success(let planned): plans = planned
            }
            for plan in plans ?? [] {
                if let driver = plan.driver, model.profile(id: driver) == nil {
                    return .failure(.notFound("no driver “\(driver)”", detail: model.drivers.profiles.map(\.id).joined(separator: ", ")))
                }
                if let chosen = plan.model, let profile = model.profile(id: plan.driver ?? params.driver), !profile.acceptsModel {
                    return .failure(.badRequest("the driver \(profile.id) takes no model (asked \(chosen) for attempt \(plan.index))"))
                }
            }
        }
        guard !params.dryRun else {
            // Nothing is written: this is the answer an agent shows before asking for the real thing.
            return .success(.task(TaskNewResult(
                created: false, name: proposal.title, slug: proposal.slug, branch: proposal.branch,
                scope: summary.name, scopeSlug: summary.slug, root: sandboxes.path,
                repos: repos.map { TaskRepoResult(repo: $0, worktree: sandboxes.appending(path: $0).path,
                                                  branch: proposal.branch,
                                                  branchCreated: startPoint.requiredBranch == nil) },
                note: note, issue: request.issue?.label,
                attempts: plans?.map { TaskAttemptResult(index: $0.index, name: $0.name, slug: $0.slug, branch: $0.branch,
                                                         model: $0.model ?? requestedModel, driver: $0.driver ?? params.driver) }
            )))
        }

        let threadOrigin = childOrigin(of: origin, caller: caller)
        // The task the caller sits in, if any: the new one is filed with it.
        let parentTask: TaskState? = if case .thread(let id, _) = origin {
            model.session(id)?.record.taskID.flatMap { raw in model.tasks.first { $0.record.id.rawValue == raw } }
        } else { nil }
        if let plans {
            let states: [TaskState]
            do {
                states = try await model.createAttempts(proposal, prompt: prompt, count: params.attempts, models: params.models,
                                                        drivers: params.drivers, driverID: params.driver, in: scope.id, repos: repos,
                                                        startPoint: startPoint, openThread: params.openThread, runSetup: params.runSetup,
                                                        threadOrigin: threadOrigin, createdBy: caller.client, parentTask: parentTask?.id,
                                                        deliverable: params.deliverable, issue: request.issue, model: requestedModel)
            } catch {
                return .failure(.failed("Scope could not create the attempts", detail: String(describing: error)))
            }
            NSApp.requestUserAttention(.informationalRequest)
            let first = states[0].record
            return .success(.task(TaskNewResult(
                created: true, task: first.id.rawValue, name: first.name, slug: first.slug, branch: first.branch,
                scope: summary.name, scopeSlug: summary.slug, root: first.root,
                repos: first.repos.map { TaskRepoResult(repo: $0.repoRelativePath, worktree: $0.sandboxPath,
                                                        branch: $0.branch, branchCreated: $0.branchCreated ?? false) },
                thread: model.threads(in: first.id).first?.id.rawValue, topic: first.topic, note: note, issue: first.issue?.label,
                attempts: zip(states, plans).map { state, plan in
                    TaskAttemptResult(index: plan.index, task: state.record.id.rawValue, name: state.record.name,
                                      slug: state.record.slug, branch: state.record.branch, model: plan.model ?? requestedModel,
                                      driver: plan.driver ?? params.driver, thread: model.threads(in: state.id).first?.id.rawValue)
                }
            )))
        }
        let topic = TaskTopic.inherit(requested: params.topic, parentTopic: parentTask?.record.topic,
                                      parentName: parentTask?.name)
        let state: TaskState
        do {
            state = try await model.createTask(proposal, prompt: prompt, driverID: params.driver, in: scope.id,
                                               repos: repos, startPoint: startPoint, openThread: params.openThread,
                                               runSetup: params.runSetup, threadOrigin: threadOrigin, createdBy: caller.client,
                                               topic: topic.child, parentTask: parentTask?.id, deliverable: params.deliverable,
                                               model: requestedModel, issue: request.issue, mission: params.mission)
        } catch {
            return .failure(.failed("Scope could not create the task", detail: String(describing: error)))
        }
        if let parentTopic = topic.parent, let parentTask {
            await model.setTopic(parentTopic, for: [parentTask.id])
        }
        NSApp.requestUserAttention(.informationalRequest)
        let record = state.record
        return .success(.task(TaskNewResult(
            created: true, task: record.id.rawValue, name: record.name, slug: record.slug, branch: record.branch,
            scope: summary.name, scopeSlug: summary.slug, root: record.root,
            repos: record.repos.map { TaskRepoResult(repo: $0.repoRelativePath, worktree: $0.sandboxPath,
                                                     branch: $0.branch, branchCreated: $0.branchCreated ?? false) },
            thread: model.threads(in: record.id).first?.id.rawValue, topic: record.topic, note: note,
            issue: record.issue?.label
        )))
    }

    /// The origin of what `origin` opens: one generation down, with the line of threads above it, so `.own` reaches
    /// grandchildren and `scope list` can show the depth.
    private func childOrigin(of origin: ControlOrigin, caller: ControlCaller) -> ThreadOrigin {
        let depth = AutomationPolicy.childDepth(of: origin)
        guard case .thread(let id, _) = origin else {
            return ThreadOrigin(author: .control, depth: depth, client: caller.client)
        }
        return .child(of: id.rawValue, origin: model.session(id)?.record.resolvedOrigin, depth: depth, client: caller.client)
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
