import Foundation
import ScopeAdapters

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
        /// When the agent's last answer arrived (`AgentReply.at`).
        public var replyAt: Date?
        /// When the app last applied a `turn.started` — a prompt or a tool report alike; `nil` before any.
        public var turnStartedAt: Date?
        /// When the thread was last handed a prompt, reported on or not.
        public var lastPromptAt: Date?
        /// Sub-agents of the driver still running (`ThreadActivity.runningAgents`): a turn that ended with one in the
        /// background is not the end of the work — the driver starts a new turn when it reports.
        public var agents: Int
        /// When its last running sub-agent finished: an answer older than that was written while it still ran
        /// ("waiting for 1 background agent"), and the one on its report is still to come.
        public var subagentsEndedAt: Date?

        public init(state: String, expectingSince: Date? = nil, reportsTurnStart: Bool = true, starting: Bool = false,
                    replyAt: Date? = nil, turnStartedAt: Date? = nil, lastPromptAt: Date? = nil, agents: Int = 0,
                    subagentsEndedAt: Date? = nil) {
            self.state = state
            self.expectingSince = expectingSince
            self.reportsTurnStart = reportsTurnStart
            self.starting = starting
            self.replyAt = replyAt
            self.turnStartedAt = turnStartedAt
            self.lastPromptAt = lastPromptAt
            self.agents = agents
            self.subagentsEndedAt = subagentsEndedAt
        }

        /// The last answer, unless the thread was handed a prompt after it: that answer is for something else.
        var currentReplyAt: Date? {
            guard let replyAt, !(lastPromptAt.map { replyAt < $0 } ?? false) else { return nil }
            return replyAt
        }
    }

    /// `true` once the thread no longer works on what it was last given: its turn ended, it needs someone (a
    /// question, a permission), or its process is gone.
    ///
    /// `waitingSince` is when the wait began: an answer that lands after it ends the wait whatever the state reads by
    /// the next look — the turn ended, even if something reopened it before the poll saw `done`.
    ///
    /// `running` is also settled when the last answer is newer than anything that started a turn (a prompt or a tool
    /// report, for a driver that reports both): no turn is in progress, whatever put the state back to `running`.
    ///
    /// A sub-agent still running in the background holds the wait whatever the turn did: the answer that ended that
    /// turn ("waiting for 3 background agents") is not the answer to the prompt, and the driver opens a new turn
    /// once the sub-agent reports. A question, a permission or an exit still settle it: someone must act. Nor does
    /// an answer that lands during the wait end it when it was written before the last sub-agent finished
    /// (`subagentsEndedAt`): the driver is about to answer on its report.
    public static func isSettled(_ snapshot: Snapshot, now: Date, waitingSince: Date? = nil) -> Bool {
        switch snapshot.state {
        case "exited", "waiting", "failed":
            return true
        default:
            break
        }
        if snapshot.agents > 0 { return false }
        // An answer written while a sub-agent still ran is not the one on its report.
        if let since = waitingSince, let reply = snapshot.currentReplyAt, reply > since,
           !(snapshot.subagentsEndedAt.map { $0 > reply } ?? false) { return true }
        switch snapshot.state {
        case "running":
            return hasOutlivedItsTurn(snapshot)
        default:
            guard let since = snapshot.expectingSince else { return true }
            return !snapshot.starting && snapshot.reportsTurnStart && now.timeIntervalSince(since) >= startGrace
        }
    }

    /// The safety net under `running`: the agent answered after the last turn start the driver reported, and nobody
    /// handed it anything since. Not for a driver that never reports a turn start (Codex): there, `running` comes
    /// from the prompt typed, which no hook timestamps.
    public static func hasOutlivedItsTurn(_ snapshot: Snapshot) -> Bool {
        guard snapshot.reportsTurnStart, snapshot.expectingSince == nil, let reply = snapshot.currentReplyAt else { return false }
        return reply > (snapshot.turnStartedAt ?? .distantPast)
    }

    /// A reply the agent gave before it was last handed a prompt answers that earlier prompt, not the latest.
    public static func isStale(_ reply: AgentReply, lastPromptAt: Date?) -> Bool {
        guard let lastPromptAt else { return false }
        return reply.at < lastPromptAt
    }

    /// Whether the wait is over for `settled`, one flag per thread waited on.
    public static func isOver(_ settled: [Bool], until: ThreadWaitParams.Until) -> Bool {
        switch until {
        case .all: settled.allSatisfy { $0 }
        case .any: settled.contains(true)
        }
    }
}
