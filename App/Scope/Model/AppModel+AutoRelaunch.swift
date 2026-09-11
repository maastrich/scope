import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

extension AppModel {
    /// Starts again the threads that were running when the app went down (spec §4.2): the one the window opens on
    /// first, the others `AutoRelaunchPlan.stagger` apart. The decision is `AutoRelaunchPlanner`'s; this only gathers
    /// the facts and carries it out. Called once by `bootstrap`, after the selection is restored.
    func autoRelaunchThreads(orphans: [ThreadRecord], skippedOnce: Bool) async {
        let candidates = threads.map { session in
            AutoRelaunchCandidate(record: session.record, task: autoRelaunchTaskStatus(of: session),
                                  driverInstalled: session.profile.id == session.record.driverID)
        } + orphans.map { AutoRelaunchCandidate(record: $0, scopeDeclared: false) }
        let plan = AutoRelaunchPlanner.plan(
            candidates,
            enabled: config.preferences.autoRelaunchThreads,
            skippedOnce: skippedOnce,
            focus: selectedThreadID,
            pathExists: { ScopeState.rootExists(URL(fileURLWithPath: $0, isDirectory: true)) }
        )

        // Not started now means not running any more: the thread must not come back at a later launch either.
        for skipped in plan.skipped {
            if let session = session(skipped.id) {
                session.forgetProcessAlive()
            } else if var record = orphans.first(where: { $0.id == skipped.id }) {
                record.processAlive = false
                await env.threadRecords.save(record)
            }
        }
        reportSkippedRelaunches(plan, orphans: orphans)

        guard !plan.launches.isEmpty else { return }
        Log.app.info("auto-relaunching \(plan.launches.count) threads")
        Task { [weak self] in
            for (index, id) in plan.launches.enumerated() {
                if index > 0 { try? await Task.sleep(for: AutoRelaunchPlan.stagger) }
                // A quit in the middle must not fork children into the dying app; the records still say they were
                // running, so they come back at the next launch.
                guard let self, !self.isTerminating else { return }
                // The user may have relaunched, stopped or closed it in the meantime.
                guard let session = self.session(id), !session.isAlive else { continue }
                if case .launching = session.phase { continue }
                let mode = LaunchMode.relaunch(profile: session.profile, resumeID: session.record.resumeID)
                let time = Date.now.formatted(date: .omitted, time: .standard)
                session.nextLaunchNotice = mode == .resume
                    ? "Scope reopened · \(session.profile.name) session resumed automatically · \(time)"
                    : "Scope reopened · restarted automatically in \(session.record.cwd) · \(time)"
                await self.launch(session, mode: mode)
            }
        }
    }

    private func autoRelaunchTaskStatus(of session: ThreadSession) -> AutoRelaunchCandidate.TaskStatus {
        guard let raw = session.record.taskID else { return .none }
        guard let task = TaskID(rawValue: raw).flatMap(task) else { return .closed }
        return task.isArchived ? .archived : .active
    }

    private func reportSkippedRelaunches(_ plan: AutoRelaunchPlan, orphans: [ThreadRecord]) {
        func title(_ id: ThreadID) -> String {
            session(id)?.title ?? orphans.first { $0.id == id }?.title ?? id.rawValue
        }
        for blocked in plan.blocked where session(blocked.id) != nil {
            autoRelaunchBlocks[blocked.id] = blocked.skip
        }
        if !plan.blocked.isEmpty {
            let count = plan.blocked.count
            problems.warn("\(count) \(count == 1 ? "thread was" : "threads were") not relaunched",
                          detail: plan.blocked.map { "\(title($0.id)) — \($0.skip.reason)" }.joined(separator: "\n"))
        }
        let skippedOnce = plan.skipped.filter { $0.skip == .skippedOnce }.count
        if skippedOnce > 0 {
            problems.report(Problem(
                severity: .info,
                title: "\(skippedOnce) \(skippedOnce == 1 ? "thread was" : "threads were") left stopped: ⇧ was held while Scope opened",
                detail: "Relaunch (⌥⌘R) brings a thread back, resuming its driver session when it can."
            ))
        }
    }
}
