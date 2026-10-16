import Foundation
import ScopeCore

/// What a task's timeline needs that would otherwise be lost: the turns of its threads once they are closed (archiving
/// a task hangs them up, and a closed thread's activity file goes with it), and the colours its checks went through.
public struct TaskTimelineLog: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Check marks kept, oldest dropped first: a pull request pushed all week still has its recent story.
    public static let checkLimit = 200

    public var version: Int
    public var lanes: [TimelineLaneSource]
    public var checks: [TaskCheckMark]

    public init(lanes: [TimelineLaneSource] = [], checks: [TaskCheckMark] = []) {
        version = Self.currentVersion
        self.lanes = lanes
        self.checks = checks
    }

    /// The log with `lane` kept as closed: a thread closed twice (closed, its record restored, closed again) keeps
    /// its latest turns once.
    public func adding(_ lane: TimelineLaneSource) -> TaskTimelineLog {
        var next = self
        var lane = lane
        lane.openTurnSince = nil
        lane.state = nil
        next.lanes.removeAll { $0.threadID == lane.threadID }
        next.lanes.append(lane)
        return next
    }

    /// The log with what a refresh saw of the checks, only when it differs from the last thing seen: refreshes are
    /// frequent, colour changes are not.
    public func recording(checks state: String, number: Int, at date: Date) -> TaskTimelineLog {
        guard ["passing", "failing", "pending"].contains(state) else { return self }
        if let last = checks.last, last.state == state, last.number == number { return self }
        var next = self
        next.checks.append(TaskCheckMark(state: state, at: date, number: number))
        if next.checks.count > Self.checkLimit { next.checks.removeFirst(next.checks.count - Self.checkLimit) }
        return next
    }
}

/// Owner of `<home>/tasks/<id>.timeline.json`, beside the task record. `TaskRecordStore.loadAll` skips it (its stem is
/// not a task id), and `TaskRecordStore.delete` reads it one last time to leave the task's totals in the history.
public actor TaskTimelineStore {
    public nonisolated let directory: URL

    public init(home: URL) {
        directory = TaskRecordStore.directoryURL(home: home)
    }

    public nonisolated func url(for id: TaskID) -> URL {
        Self.url(for: id, in: directory)
    }

    static func url(for id: TaskID, in directory: URL) -> URL {
        directory.appending(path: "\(id.rawValue).timeline.json", directoryHint: .notDirectory)
    }

    /// An empty log when there is none, or it is unreadable or from another version: history, never state.
    public func load(_ id: TaskID) -> TaskTimelineLog {
        Self.load(from: url(for: id))
    }

    static func load(from url: URL) -> TaskTimelineLog {
        guard let log = try? JSONStore.load(TaskTimelineLog.self, from: url, fractionalSeconds: true),
              log.version == TaskTimelineLog.currentVersion else { return TaskTimelineLog() }
        return log
    }

    public func update(_ id: TaskID, _ change: (TaskTimelineLog) -> TaskTimelineLog) {
        let current = load(id)
        let next = change(current)
        guard next != current else { return }
        do {
            try JSONStore.save(next, to: url(for: id), fractionalSeconds: true)
        } catch {
            Log.tasks.error("task timeline \(id) write failed: \(String(describing: error))")
        }
    }

    /// Missing file is not an error.
    public func delete(_ id: TaskID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
