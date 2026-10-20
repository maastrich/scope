import Foundation
import ScopeCore

/// When each open task's pull request is asked about again, off screen.
///
/// The inspector keeps the task on screen fresh every minute; every other task used to keep what `gh` said on its
/// last visit. The app's background pass asks this schedule which tasks are due, refreshes them a few at a time and
/// reports back. A task is due `interval` after its last attempt; a failed attempt doubles the wait, up to
/// `maximumBackoff`, so a task whose repository is gone or whose network is down stops costing a `gh` call every pass.
/// A pull request already merged or closed changes rarely: `settledInterval`.
///
/// Tasks never attempted are spread over the first interval (`stagger`) rather than all asked at launch.
public struct PullRequestRefreshSchedule: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// When the last refresh started; `nil` before the first one.
        public var lastAttempt: Date?
        /// Failures in a row since the last success.
        public var failures: Int
        /// The pull request was last seen merged or closed.
        public var settled: Bool
        /// When the task joined the schedule: what a never-attempted task's stagger counts from.
        public var addedAt: Date

        public init(lastAttempt: Date? = nil, failures: Int = 0, settled: Bool = false, addedAt: Date) {
            self.lastAttempt = lastAttempt
            self.failures = failures
            self.settled = settled
            self.addedAt = addedAt
        }
    }

    public static let defaultInterval: TimeInterval = 5 * 60

    public var interval: TimeInterval
    public var settledInterval: TimeInterval
    public var maximumBackoff: TimeInterval
    /// `gh` calls in flight at once.
    public var concurrency: Int
    public private(set) var entries: [TaskID: Entry] = [:]

    public init(interval: TimeInterval = PullRequestRefreshSchedule.defaultInterval, settledInterval: TimeInterval = 30 * 60,
                maximumBackoff: TimeInterval = 60 * 60, concurrency: Int = 2) {
        self.interval = interval
        self.settledInterval = settledInterval
        self.maximumBackoff = maximumBackoff
        self.concurrency = concurrency
    }

    /// Keeps the schedule to `tasks`, in their order: new ones join with a stagger slot, gone ones leave.
    public mutating func sync(_ tasks: [TaskID], now: Date) {
        let live = Set(tasks)
        entries = entries.filter { live.contains($0.key) }
        for id in tasks where entries[id] == nil {
            entries[id] = Entry(addedAt: now)
        }
    }

    /// When `id` is next due; `nil` for a task not in the schedule.
    public func nextDue(_ id: TaskID) -> Date? {
        guard let entry = entries[id] else { return nil }
        guard let last = entry.lastAttempt else { return entry.addedAt.addingTimeInterval(stagger(id)) }
        let base = entry.settled ? settledInterval : interval
        guard entry.failures > 0 else { return last.addingTimeInterval(base) }
        // 2×, 4×, 8× … the interval, capped.
        let backoff = base * pow(2, Double(min(entry.failures, 16)))
        return last.addingTimeInterval(min(max(backoff, base), max(maximumBackoff, base)))
    }

    /// The tasks due at `now`, the longest overdue first.
    public func due(at now: Date) -> [TaskID] {
        var due: [(id: TaskID, at: Date)] = []
        for id in entries.keys {
            if let at = nextDue(id), at <= now { due.append((id, at)) }
        }
        due.sort { lhs, rhs in lhs.at == rhs.at ? lhs.id.rawValue < rhs.id.rawValue : lhs.at < rhs.at }
        return due.map(\.id)
    }

    public mutating func started(_ id: TaskID, at now: Date) {
        entries[id]?.lastAttempt = now
    }

    /// The refresh answered; `settled` when the pull request is merged or closed.
    public mutating func succeeded(_ id: TaskID, settled: Bool) {
        entries[id]?.failures = 0
        entries[id]?.settled = settled
    }

    public mutating func failed(_ id: TaskID) {
        entries[id]?.failures += 1
    }

    /// A stable offset in `[0, interval)` from the id: the same task lands in the same slot on every launch, and a
    /// dozen tasks opened together do not all call `gh` in the same second.
    func stagger(_ id: TaskID) -> TimeInterval {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 10_000) / 10_000 * interval
    }
}

/// How old what Scope knows of a pull request is, and when that is too old to colour.
public enum PullRequestFreshness {
    /// Past this many background intervals, checks are shown neutral: green or red that old may be a lie.
    public static let staleAfterIntervals = 3.0

    public static func isStale(checkedAt: Date?, now: Date,
                               interval: TimeInterval = PullRequestRefreshSchedule.defaultInterval) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) > interval * staleAfterIntervals
    }

    /// `just now`, `4 min ago`, `2 h ago`, `3 d ago`.
    public static func age(since checkedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(checkedAt))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}
