import Foundation
import ScopeAdapters
import ScopeCore
import ScopeGit
import ScopeTasks

/// The task timeline's data: the live threads' activity, plus what `TaskTimelineLog` keeps once a thread is closed
/// (archiving hangs every thread up) and the colours the checks went through.
extension AppModel {
    /// Keeps a task thread's turns in its task's timeline, before the thread's activity file goes with its record.
    func keepTimeline(of record: ThreadRecord, activity: ThreadActivity?) async {
        guard let raw = record.taskID, let taskID = TaskID(rawValue: raw) else { return }
        var kept = activity
        if kept == nil { kept = await env.threadActivity.load(record.id) }
        guard let kept, !kept.turns.isEmpty || kept.inTurn else { return }
        let now = Date.now
        let lane = TimelineLaneSource(threadID: record.id.rawValue, title: record.title, driverID: record.driverID,
                                      createdAt: record.createdAt, closedAt: now, turns: kept.closingOpenTurn(at: now).turns)
        await env.taskTimelines.update(taskID) { $0.adding(lane) }
        await reloadTimelineLog(of: taskID)
    }

    /// What a refresh saw of the checks, kept when the colour changed.
    func recordChecks(of pr: PullRequest, for task: TaskState) async {
        guard pr.checks != .none else { return }
        let now = Date.now
        await env.taskTimelines.update(task.id) { $0.recording(checks: pr.checks.rawValue, number: pr.number, at: now) }
        await reloadTimelineLog(of: task.id)
    }

    func reloadTimelineLog(of taskID: TaskID) async {
        let log = await env.taskTimelines.load(taskID)
        task(taskID)?.timelineLog = log
    }

    /// One lane per thread: the live ones from their sessions, the closed ones from the log. A thread brought back by
    /// Undo Close is live again, and its kept copy is left out.
    func timelineLanes(of task: TaskState) -> [TimelineLaneSource] {
        let live = threads(in: task.id).map { session in
            TimelineLaneSource(threadID: session.id.rawValue, title: session.title, driverID: session.record.driverID,
                               createdAt: session.record.createdAt, turns: session.activity.turns,
                               openTurnSince: session.activity.turnStartedAt, state: session.displayState)
        }
        let liveIDs = Set(live.map(\.threadID))
        return live + (task.timelineLog?.lanes ?? []).filter { !liveIDs.contains($0.threadID) }
    }

    func timeline(of task: TaskState, now: Date) -> TaskTimeline {
        let prs = task.record.pullRequests.map { (number: $0.number, openedAt: $0.openedAt, mergedAt: $0.mergedAt, closedAt: $0.closedAt) }
        return TaskTimeline.build(createdAt: task.record.createdAt, archivedAt: task.record.archivedAt, now: now,
                                  pullRequests: prs, checks: task.timelineLog?.checks ?? [], lanes: timelineLanes(of: task))
    }

    /// The task as `scope summary` sees it, with the time its agents worked and waited.
    func summarySnapshot(of record: TaskRecord) async -> TaskSnapshot {
        guard let task = task(record.id) else { return record.snapshot }
        if task.timelineLog == nil { await reloadTimelineLog(of: record.id) }
        return record.snapshot(lanes: timelineLanes(of: task))
    }
}
