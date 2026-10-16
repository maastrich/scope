import AppKit
import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeGit
import ScopeTasks

/// Scheduled prompts (spec §4.11): every minute, the schedules of every scope are checked against the clock
/// (`Scheduler.due`, pure) and the due ones fire — the prompt goes to the scope's orchestrator the way *Ask
/// Orchestrator…* sends it, or opens a task the way `scope task new` does. The run is recorded on the schedule at
/// once, so the next tick cannot fire it again, and completed when the agent answers: the first line of its reply is
/// what the Inbox shows under *Schedule <name> ran*.
extension AppModel {
    static let scheduleTick: Duration = .seconds(60)
    /// How long a run waits for the agent's reply before it is recorded without one.
    static let scheduleReplyTimeout: TimeInterval = 30 * 60
    /// The client name a run created by a schedule carries on its task and thread.
    static let scheduleClient = "scope-schedule/1"

    func startSchedules() {
        scheduler?.cancel()
        scheduleWatchedSince = .now
        scheduler = Task { [weak self] in
            guard let self else { return }
            // Launch: a daily prompt missed today fires once, when the preference says so.
            self.fireDueSchedules(catchUp: self.config.preferences.catchUpSchedules)
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.scheduleTick)
                guard !Task.isCancelled else { return }
                self.fireDueSchedules(catchUp: false)
            }
        }
    }

    /// One tick: what `Scheduler` says is due fires, each run on its own.
    func fireDueSchedules(catchUp: Bool, now: Date = .now) {
        guard !isTerminating else { return }
        for scope in scopes {
            for schedule in Scheduler.due(scope.declaration.schedules, now: now, watchedSince: scheduleWatchedSince, catchUp: catchUp) {
                fireSchedule(schedule, in: scope.id, now: now)
            }
        }
    }

    /// Fires `schedule` now — the tick, Settings' *Run now*, `scope schedule run`. Returns at once with what went out;
    /// the reply is waited for in the background and lands in the Inbox. `nil` when a run of it is still in flight.
    @discardableResult
    func fireSchedule(_ schedule: Schedule, in scopeID: ScopeID, now: Date = .now) -> ScheduleRun? {
        guard !runningSchedules.contains(schedule.id), let scope = scope(scopeID) else { return nil }
        runningSchedules.insert(schedule.id)
        Usage.click("schedule.fire", label: "A schedule fired")
        let dispatched: ScheduleRun
        switch schedule.target.kind {
        case .orchestrator:
            dispatched = sendScheduledPrompt(schedule, to: scope, at: now)
        case .newTask:
            dispatched = ScheduleRun(at: now, outcome: .noReply)
        }
        recordScheduleRun(dispatched, of: schedule.id, in: scopeID)
        Task { [weak self] in
            guard let self else { return }
            var run = dispatched
            if schedule.target.kind == .newTask {
                run = await self.openScheduledTask(schedule, in: scope, at: now)
                self.recordScheduleRun(run, of: schedule.id, in: scopeID)
            }
            if run.outcome != .failed, let raw = run.thread, let thread = ThreadID(rawValue: raw) {
                run = await self.awaitScheduledReply(run, from: thread, since: now)
                self.recordScheduleRun(run, of: schedule.id, in: scopeID)
            }
            self.runningSchedules.remove(schedule.id)
            if run.outcome == .failed {
                self.problems.warn("The schedule “\(schedule.name)” did not run", detail: run.summary, scope: scopeID)
            }
        }
        return dispatched
    }

    /// The orchestrator target: the envelope is typed into the scope's orchestrator, started if it was stopped.
    private func sendScheduledPrompt(_ schedule: Schedule, to scope: ScopeState, at now: Date) -> ScheduleRun {
        guard let id = UserMessage.orchestrator(of: scope.id, in: threads.map(\.record)), session(id) != nil else {
            return ScheduleRun(at: now, outcome: .failed, summary: "\(scope.name) has no orchestrator thread")
        }
        guard sendMessage(schedule.envelope, to: id, toast: false) else {
            return ScheduleRun(at: now, outcome: .failed, summary: "the prompt is empty")
        }
        return ScheduleRun(at: now, outcome: .noReply, thread: id.rawValue)
    }

    /// The new-task target: `task.new` with the schedule's driver and model, titled after the schedule and the moment,
    /// on a branch of its own — named by Scope, so no proposal is asked of the driver.
    private func openScheduledTask(_ schedule: Schedule, in scope: ScopeState, at now: Date) async -> ScheduleRun {
        guard let service = env.controls.service else {
            return ScheduleRun(at: now, outcome: .failed, summary: "Scope is still starting up")
        }
        let stamp = now.formatted(Date.FormatStyle().year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let title = "\(schedule.name) · \(stamp)"
        let branch = "schedule/" + TaskBranch.slug(for: title)
        let params = TaskNewParams(prompt: schedule.envelope, scope: scope.id.rawValue, branch: branch, title: title,
                                   driver: schedule.target.driver, topic: "schedules", model: schedule.target.model)
        let caller = ControlCaller(client: AppModel.scheduleClient)
        switch await service.perform(.taskNew(params), from: .user, caller: caller, progress: { _ in }) {
        case .success(.task(let result)):
            guard let thread = result.thread else {
                return ScheduleRun(at: now, outcome: .failed, summary: "the task \(result.slug) opened no thread", task: result.task)
            }
            return ScheduleRun(at: now, outcome: .noReply, thread: thread, task: result.task)
        case .success:
            return ScheduleRun(at: now, outcome: .failed, summary: "unexpected answer from task.new")
        case .failure(let error):
            return ScheduleRun(at: now, outcome: .failed, summary: error.message)
        }
    }

    /// Waits for the thread's turn to end — the same rule as `scope thread wait` — then keeps the first line of the
    /// reply. Past the timeout the run stays `noReply`; the Inbox then points at the thread.
    private func awaitScheduledReply(_ run: ScheduleRun, from id: ThreadID, since: Date) async -> ScheduleRun {
        let deadline = since.addingTimeInterval(AppModel.scheduleReplyTimeout)
        while Date.now < deadline, !isTerminating {
            guard let session = session(id) else { return run }
            session.settleOutlivedTurn()
            if ThreadWait.isSettled(session.waitSnapshot, now: .now, waitingSince: since) { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let session = session(id), let reply = session.activity.lastReply ?? session.lastReply, reply.at >= since else {
            return run
        }
        var done = run
        done.outcome = .replied
        done.summary = Inbox.headline(reply.text) ?? "(empty reply)"
        return done
    }

    // MARK: Config

    /// The schedule `id` of `scopeID`, as the config holds it now.
    func schedule(_ id: String, in scopeID: ScopeID) -> Schedule? {
        scope(scopeID)?.declaration.schedules.first { $0.id == id }
    }

    /// Adds or replaces a schedule, keeping the last run of the one it replaces.
    func saveSchedule(_ schedule: Schedule, in scopeID: ScopeID) {
        updateScopeIdentity(scopeID) { declaration in
            var schedule = schedule
            if let index = declaration.schedules.firstIndex(where: { $0.id == schedule.id }) {
                if schedule.lastRun == nil { schedule.lastRun = declaration.schedules[index].lastRun }
                declaration.schedules[index] = schedule
            } else {
                declaration.schedules.append(schedule)
            }
        }
    }

    func removeSchedule(_ id: String, from scopeID: ScopeID) {
        updateScopeIdentity(scopeID) { $0.schedules.removeAll { $0.id == id } }
    }

    func setSchedule(_ id: String, in scopeID: ScopeID, enabled: Bool) {
        updateScopeIdentity(scopeID) { declaration in
            guard let index = declaration.schedules.firstIndex(where: { $0.id == id }) else { return }
            declaration.schedules[index].enabled = enabled
        }
    }

    private func recordScheduleRun(_ run: ScheduleRun, of id: String, in scopeID: ScopeID) {
        updateScopeIdentity(scopeID) { declaration in
            guard let index = declaration.schedules.firstIndex(where: { $0.id == id }) else { return }
            declaration.schedules[index].lastRun = run
        }
    }

    // MARK: Control

    /// The schedules `schedule.list` describes: one scope's, or every scope's.
    func scheduleSummaries(in scopeID: ScopeID? = nil, now: Date = .now) -> [ScheduleSummary] {
        scopes.filter { scopeID == nil || $0.id == scopeID }.flatMap { scope in
            scope.declaration.schedules.map { ScheduleSummary($0, scope: scope.name, scopeSlug: scope.declaration.slug, now: now) }
        }
    }

    /// The schedule `name` names (id or name), in `scopeID` or in any scope. Several matches want a `--scope`.
    func findSchedule(_ name: String, in scopeID: ScopeID?) -> Result<(Schedule, ScopeID), ControlError> {
        let matches = scopes.filter { scopeID == nil || $0.id == scopeID }
            .flatMap { scope in scope.declaration.schedules.filter { $0.matches(name) }.map { ($0, scope) } }
        guard let first = matches.first else {
            return .failure(.notFound("no schedule called “\(name)”",
                                      detail: "`scope schedule list` shows them; Settings ▸ Automation ▸ Schedules adds one."))
        }
        guard matches.count == 1 else {
            return .failure(.badRequest("“\(name)” names a schedule in several scopes",
                                        detail: "Say which with --scope: " + matches.map { "\($1.declaration.slug)/\($0.name)" }.joined(separator: ", ")))
        }
        return .success((first.0, first.1.id))
    }

    // MARK: Inbox

    /// Every schedule with a run, for `Inbox.items`.
    var inboxScheduleInputs: [Inbox.ScheduleInput] {
        scopes.flatMap { scope in
            scope.declaration.schedules.compactMap { schedule in
                guard let run = schedule.lastRun else { return nil }
                return Inbox.ScheduleInput(id: schedule.id, scopeID: scope.id, name: schedule.name, run: run,
                                           taskID: run.task.flatMap(TaskID.init(rawValue:)),
                                           threadID: run.thread.flatMap(ThreadID.init(rawValue:)))
            }
        }
    }
}
