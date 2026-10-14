import Foundation

/// When a thread is done with what it was last given, for `thread.wait`.
///
/// The state alone cannot say it. A thread handed a prompt a moment ago still reads `idle` until its driver
/// reports the turn starting — a launch with a prompt takes seconds, a message is typed and then ↩ is pressed —
/// so "not running" would answer before the work even began. Each thread therefore carries the time it was last
/// handed something (`expectingSince`), cleared by the driver's next report; until that report, the thread is
/// still at work.
public enum ThreadWait {
    /// How long a turn may take to start before the thread counts as settled anyway: a prompt the driver never
    /// picked up (a trust dialog, a crash at launch) must not hold a wait until its deadline.
    public static let startGrace: TimeInterval = 90

    /// What the app knows of one thread at one instant.
    public struct Snapshot: Sendable, Equatable {
        /// `ThreadState.name`: `idle`, `running`, `waiting`, `done`, `failed`, `exited`.
        public var state: String
        /// When it was last handed a prompt its driver has not reported on yet; `nil` once it has.
        public var expectingSince: Date?
        /// The driver reports the start of a turn (Claude Code). Without it (Codex `notify`), only the end of the
        /// turn says anything, so an expectation is never given up on a timer: the turn may simply be long.
        public var reportsTurnStart: Bool
        /// The process is not up yet: the shell environment is being read, or the task's setup still runs —
        /// which can take minutes, so the grace only starts once the driver does.
        public var starting: Bool

        public init(state: String, expectingSince: Date? = nil, reportsTurnStart: Bool = true, starting: Bool = false) {
            self.state = state
            self.expectingSince = expectingSince
            self.reportsTurnStart = reportsTurnStart
            self.starting = starting
        }
    }

    /// `true` once the thread no longer works on what it was last given: its turn ended, it needs someone (a
    /// question, a permission), or its process is gone.
    public static func isSettled(_ snapshot: Snapshot, now: Date) -> Bool {
        switch snapshot.state {
        case "exited", "waiting", "failed":
            return true
        case "running":
            return false
        default:
            guard let since = snapshot.expectingSince else { return true }
            return !snapshot.starting && snapshot.reportsTurnStart && now.timeIntervalSince(since) >= startGrace
        }
    }

    /// Whether the wait is over for `settled`, one flag per thread waited on.
    public static func isOver(_ settled: [Bool], until: ThreadWaitParams.Until) -> Bool {
        switch until {
        case .all: settled.allSatisfy { $0 }
        case .any: settled.contains(true)
        }
    }
}
