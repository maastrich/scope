import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks

/// Missions (spec §4.3): Scope keeps the milestones on the parent task's record and runs each one's validation in
/// the sandbox when it is marked done. The orchestrator plans; nothing here decides what the next milestone is.
extension AppModel {
    /// The mission `task` belongs to: itself when it is one, else the nearest ancestor that is. `nil` outside any.
    func mission(of task: TaskState) -> TaskState? {
        var current: TaskState? = task
        var hops = 0
        while let candidate = current, hops < 16 {
            if candidate.record.isMission { return candidate }
            current = candidate.record.parentTask.flatMap(self.task)
            hops += 1
        }
        return nil
    }

    /// `scope task milestone add`: names a milestone on `mission`.
    func addMilestone(to mission: TaskState, title: String, validation: String?, child: TaskID?) async -> Result<Milestone, ControlError> {
        guard var record = mission.record.mission else { return .failure(.badRequest("\(mission.record.slug) is not a mission")) }
        let milestone: Milestone
        switch record.add(title: title, validation: validation, task: child) {
        case .failure(let error): return .failure(.badRequest(error.description))
        case .success(let added): milestone = added
        }
        do {
            try await saveMission(record, of: mission)
        } catch {
            return .failure(.failed("could not save the milestone", detail: String(describing: error)))
        }
        return .success(milestone)
    }

    /// `scope task milestone done`: marks the milestone done, runs its validation in the child's sandbox (the
    /// mission's without a child), records the verdict, and sends a failure to the milestone's thread. Answers once
    /// the validation is over.
    func markMilestoneDone(_ mission: TaskState, reference: String, child: TaskID?) async -> Result<Milestone, ControlError> {
        guard var record = mission.record.mission else { return .failure(.badRequest("\(mission.record.slug) is not a mission")) }
        guard let index = record.index(of: reference) else {
            return .failure(.notFound("no milestone “\(reference)” on \(mission.record.slug)",
                                      detail: record.milestones.isEmpty ? "The mission has no milestones yet."
                                          : record.milestones.enumerated().map { "\($0 + 1). \($1.title) [\($1.state.rawValue)]" }.joined(separator: "\n")))
        }
        let now = Date.now
        switch record.markDone(index, task: child, at: now) {
        case .failure(let error): return .failure(.badRequest(error.description))
        case .success: break
        }
        do {
            try await saveMission(record, of: mission)
        } catch {
            return .failure(.failed("could not save the milestone", detail: String(describing: error)))
        }
        let milestone = record.milestones[index]
        guard let command = milestone.validation else { return .success(milestone) }

        Usage.click("mission.validate", label: "A milestone's validation ran")
        let worker = milestone.task.flatMap(task).flatMap { $0.isArchived ? nil : $0 } ?? mission
        let cwd = worker.record.threadCwd
        var environment = worker.record.environment
        environment["SCOPE_SANDBOX"] = cwd.path
        environment["SCOPE_SCOPE"] = scope(worker.scopeID)?.declaration.slug ?? worker.record.scopeSlug
        let runner = await validationRunner()
        let outcome = await runner.run(command, in: cwd, environment: environment, timeout: Mission.validationTimeout)

        // The record may have moved on (another milestone added) while the command ran: apply to the current one.
        guard var latest = task(mission.id)?.record.mission, let current = latest.index(of: milestone.id) else {
            return .failure(.failed("the mission went away while the validation ran"))
        }
        latest.applyValidation(current, succeeded: outcome.succeeded, exit: outcome.summary, output: outcome.output, at: .now)
        do {
            try await saveMission(latest, of: mission)
        } catch {
            return .failure(.failed("could not record the validation", detail: String(describing: error)))
        }
        let verdict = latest.milestones[current]
        if verdict.state == .failed {
            sendValidationFailure(verdict, command: command, worker: worker, mission: mission)
        }
        return .success(verdict)
    }

    private func saveMission(_ record: Mission, of mission: TaskState) async throws {
        let saved = try await env.tasks.setMission(record, for: mission.id)
        mission.update(record: saved)
        // The context file lists the milestones: the agent reads the state there too.
        await regenerateContextFile(of: mission)
    }

    private func validationRunner() async -> ShellCommandRunner {
        let shell = await env.shell.environment()
        return ShellCommandRunner(shell: shell.shell, baseEnvironment: shell.variables)
    }

    /// The log goes to the thread that did the milestone: the child task's agent, else the mission's.
    private func sendValidationFailure(_ milestone: Milestone, command: String, worker: TaskState, mission: TaskState) {
        let text = Mission.failureMessage(milestone: milestone, command: command)
        let candidates = (worker.id == mission.id ? [] : threads(in: worker.id)) + threads(in: mission.id)
        guard let thread = candidates.first(where: { $0.isAlive && $0.deliversEvents }) else {
            problems.warn("The validation of “\(milestone.title)” failed", detail: text, scope: mission.scopeID)
            return
        }
        if case .failed(let why) = deliver(text, to: thread.id, label: "milestone validation") {
            problems.warn("The validation of “\(milestone.title)” failed", detail: "\(why)\n\n\(text)", scope: mission.scopeID)
        }
    }

    /// Rewrites the context files of `task` from its current record (after a milestone changed).
    func regenerateContextFile(of task: TaskState) async {
        guard let scope = scope(task.scopeID) else { return }
        let summaries = await graphSummaries(for: scope)
        do {
            try await env.tasks.regenerateProjection(task.id, scopeContext: scope.declaration.context, scopeRepos: scope.repos.map(\.id),
                                                     repoSummaries: summaries, contextFiles: contextFileNames)
        } catch {
            Log.tasks.error("context file refresh failed for \(task.record.slug, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
