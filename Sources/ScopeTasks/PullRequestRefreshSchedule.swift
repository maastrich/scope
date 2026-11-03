import Foundation
import ScopeCore
import ScopeGit

/// When each open task's pull request is asked about again.
///
/// The app's background pass asks this schedule which tasks are due, refreshes them a few at a time and reports back;
/// the inspector asks it whether the task on screen is due (`foregroundDue`). A task is due one interval after its last
/// attempt; a failed attempt doubles the wait, up to `maximumBackoff`, so a task whose repository is gone stops costing
/// a `gh` call every pass. A pull request already merged or closed changes rarely: `settledInterval`.
///
/// The intervals stretch with `attention` — nobody reads a pull request's checks at 3 a.m. — except for a task whose
/// thread is at work (`Entry.busy`): an agent working unattended still needs its failed check or its review noticed.
/// `PullRequestRefreshGate` decides whether any call goes out at all (network, sleep, an outage).
///
/// Tasks never attempted are spread over the first interval (`stagger`) rather than all asked at launch.
public struct PullRequestRefreshSchedule: Sendable, Equatable {
    /// Whether someone is likely looking at Scope, as the app reads it from the system.
    public enum Attention: String, Sendable, CaseIterable {
        /// Scope is frontmost and someone touched the keyboard or the pointer lately.
        case active
        /// Another app is frontmost, but someone is at the Mac.
        case background
        /// The screen is locked, the displays are asleep, or nobody has touched anything for `awayAfter`.
        case away

        /// No input for this long counts as gone: long enough that reading a long answer is not leaving.
        public static let awayAfter: TimeInterval = 10 * 60

        /// From what the system says: the lock screen or sleeping displays, how long since the last input in any app,
        /// and whether Scope is frontmost.
        public static func resolve(frontmost: Bool, locked: Bool, displaysAsleep: Bool, idleSeconds: TimeInterval) -> Attention {
            if locked || displaysAsleep || idleSeconds >= awayAfter { return .away }
            return frontmost ? .active : .background
        }

        /// How much longer than in `active` every interval is. `background`: the person is one ⌘-Tab away, and
        /// coming back makes every task due at once anyway (its last attempt is older than the active interval).
        /// `away`: one check an hour still archives a task whose pull request merged overnight, and that is all
        /// anyone needs before they are back.
        public var stretch: Double {
            switch self {
            case .active: 1
            case .background: 2
            case .away: 12
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        /// When the last refresh started; `nil` before the first one.
        public var lastAttempt: Date?
        /// Failures in a row since the last success.
        public var failures: Int
        /// The pull request was last seen merged or closed.
        public var settled: Bool
        /// When the task joined the schedule: what a never-attempted task's stagger counts from.
        public var addedAt: Date
        /// Its open pull request is likely to get a review soon — just opened, review requested, a batch of comments
        /// still coming in: asked about every `eagerInterval` rather than every `interval`.
        public var eager = false
        /// A thread of the task is at work or waiting: kept at the active cadence whoever is looking.
        public var busy = false

        public init(lastAttempt: Date? = nil, failures: Int = 0, settled: Bool = false, addedAt: Date) {
            self.lastAttempt = lastAttempt
            self.failures = failures
            self.settled = settled
            self.addedAt = addedAt
        }
    }

    public static let defaultInterval: TimeInterval = 5 * 60
    /// The cadence of an eager entry: a Copilot review lands within minutes of the pull request opening.
    public static let eagerInterval: TimeInterval = 90
    /// The task on screen, while Scope is frontmost: what notices the pull request a thread just opened.
    public static let foregroundInterval: TimeInterval = 60

    public var interval: TimeInterval
    public var settledInterval: TimeInterval
    public var maximumBackoff: TimeInterval
    /// `gh` calls in flight at once.
    public var concurrency: Int
    public var attention: Attention = .active
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

    /// Adds one task without waiting for the next `sync`: the task on screen that just got something to ask about.
    public mutating func include(_ id: TaskID, now: Date) {
        if entries[id] == nil { entries[id] = Entry(addedAt: now) }
    }

    /// The wait after a successful attempt, before any backoff.
    func baseInterval(_ entry: Entry) -> TimeInterval {
        // A busy task is looked at as if someone were: its agent is the one reading.
        let stretch = entry.busy ? 1 : attention.stretch
        if entry.settled { return settledInterval * stretch }
        if entry.eager, attention != .away || entry.busy { return min(Self.eagerInterval * stretch, interval) }
        return interval * stretch
    }

    /// When `id` is next due; `nil` for a task not in the schedule.
    public func nextDue(_ id: TaskID) -> Date? {
        guard let entry = entries[id] else { return nil }
        guard let last = entry.lastAttempt else { return entry.addedAt.addingTimeInterval(stagger(id)) }
        return last.addingTimeInterval(wait(entry, base: baseInterval(entry)))
    }

    /// `base`, or after failures 2×, 4×, 8× … `base`, capped at `maximumBackoff` (never below `base`).
    private func wait(_ entry: Entry, base: TimeInterval) -> TimeInterval {
        guard entry.failures > 0 else { return base }
        let backoff = base * pow(2, Double(min(entry.failures, 16)))
        return min(max(backoff, base), max(maximumBackoff, base))
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

    /// Whether the task on screen is due for the inspector's faster refresh: only while Scope is in front, one
    /// `foregroundInterval` after any attempt (the background pass's included), backing off on failures like the rest.
    /// A task not in the schedule is never due: `include` it first.
    public func foregroundDue(_ id: TaskID, at now: Date) -> Bool {
        guard attention == .active, let entry = entries[id] else { return false }
        guard let last = entry.lastAttempt else { return true }
        return now >= last.addingTimeInterval(wait(entry, base: Self.foregroundInterval))
    }

    public mutating func started(_ id: TaskID, at now: Date) {
        entries[id]?.lastAttempt = now
    }

    /// The refresh answered; `settled` when the pull request is merged or closed.
    public mutating func succeeded(_ id: TaskID, settled: Bool) {
        entries[id]?.failures = 0
        entries[id]?.settled = settled
    }

    public mutating func setEager(_ id: TaskID, _ eager: Bool) {
        entries[id]?.eager = eager
    }

    public mutating func setBusy(_ id: TaskID, _ busy: Bool) {
        entries[id]?.busy = busy
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

/// Whether any pull request refresh may call `gh` right now, whatever task it is for.
///
/// Nothing goes out while the Mac sleeps or the network is down (`NWPathMonitor`), nor for `resumeGrace` after either
/// comes back: the first seconds after a wake, DNS and the VPN are not ready and every call would fail. And an outage
/// the network monitor does not see — GitHub down, a captive portal, a token revoked, a rate limit — backs every
/// refresh off together after the first failure of that kind (`GhFailure.isGlobal`): 1, 2, 4 … minutes up to
/// `maximumBackoff`, at least `rateLimitBackoff` for a rate limit, back to normal at the first success.
public struct PullRequestRefreshGate: Sendable, Equatable {
    public static let resumeGrace: TimeInterval = 20
    public static let firstBackoff: TimeInterval = 60
    public static let maximumBackoff: TimeInterval = 60 * 60
    /// GitHub's secondary limits last minutes; asking again sooner only extends them.
    public static let rateLimitBackoff: TimeInterval = 15 * 60

    public private(set) var online = true
    public private(set) var asleep = false
    /// When the Mac woke or the network came back.
    public private(set) var resumedAt: Date?
    /// Global failures in a row since the last success.
    public private(set) var streak = 0
    public private(set) var lastFailure: Date?
    public private(set) var lastCause: GhFailure?

    public init() {}

    public mutating func setOnline(_ online: Bool, at now: Date) {
        guard online != self.online else { return }
        self.online = online
        if online { resumedAt = now }
    }

    public mutating func setAsleep(_ asleep: Bool, at now: Date) {
        guard asleep != self.asleep else { return }
        self.asleep = asleep
        if !asleep { resumedAt = now }
    }

    /// When calls may go out again; `nil` while the network is down or the Mac asleep (no date to wait for).
    public func nextAllowed() -> Date? {
        guard online, !asleep else { return nil }
        var at = resumedAt.map { $0.addingTimeInterval(Self.resumeGrace) } ?? .distantPast
        if streak > 0, let lastFailure {
            var backoff = min(Self.firstBackoff * pow(2, Double(min(streak - 1, 16))), Self.maximumBackoff)
            if lastCause == .rateLimit { backoff = max(backoff, Self.rateLimitBackoff) }
            at = max(at, lastFailure.addingTimeInterval(backoff))
        }
        return at
    }

    public func allows(at now: Date) -> Bool {
        nextAllowed().map { now >= $0 } ?? false
    }

    /// A call answered: whatever was wrong is over.
    public mutating func succeeded() {
        streak = 0
        lastCause = nil
    }

    /// A call failed. Only a failure that says nothing about one task (`GhFailure.isGlobal`) holds everything back.
    public mutating func failed(_ cause: GhFailure, at now: Date) {
        guard cause.isGlobal else { return }
        streak += 1
        lastFailure = now
        lastCause = cause
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
