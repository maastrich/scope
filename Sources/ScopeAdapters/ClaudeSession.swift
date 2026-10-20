import Foundation

/// What a Claude Code thread is doing beyond its turn: everything Scope reads from its hooks (`ClaudeHookFacts`) and
/// its transcript (`ClaudeTranscriptRecord`) that is not the turn-taking `ThreadActivity` already folds.
///
/// Kept apart from `ThreadActivity` on purpose. The activity drops a report that arrives once the turn is over
/// (`ThreadActivity.isLate`) — right for the thread's state, wrong here: a background command finishing, a sub-agent
/// reporting, a compaction while idle all happen between turns, and this is where they land. Lives in memory with the
/// thread; nothing here is written to disk, and a relaunch rebuilds it from the transcript.
///
/// Equal values mean nothing a view shows moved: keep it free of timestamps that change on every hook.
///
/// Each feature adds its own value here (a stored property with an `apply` for facts and one for records) and calls
/// them from the two `apply` below, so features never edit each other's code.
public struct ClaudeSession: Sendable, Equatable {
    /// The session these facts belong to (`session_id`).
    public var sessionID: String?
    /// The permission mode as the last hook or transcript record said: `default`, `plan`, `acceptEdits`, `auto`,
    /// `dontAsk`, `bypassPermissions`.
    public var permissionMode: String?
    /// The reasoning effort the last tool hook ran at (`effort.level`).
    public var effort: String?
    /// Background shells, Monitors, the `/loop` wake-up and the crons (`ClaudeBackgroundWork`).
    public var background = ClaudeBackgroundWork()

    public init() {}

    /// `SessionStart` sources that begin a new conversation: what the previous one ran is gone with it. A resume, a
    /// fork or a compaction goes on with the same work.
    public static let freshSources: Set<String> = ["startup", "clear"]

    /// Folds one hook.
    public mutating func apply(_ facts: ClaudeHookFacts) {
        if facts.event == "SessionStart", let source = facts.body["source"]?.string, Self.freshSources.contains(source) {
            self = ClaudeSession()
        }
        if let id = facts.sessionID { sessionID = id }
        // A sub-agent's hook carries the sub-agent's own mode and effort, not the session's.
        if facts.agentID == nil {
            if let mode = facts.permissionMode { permissionMode = mode }
            if let effort = facts.effort { self.effort = effort }
        }
        background.apply(facts)
    }

    /// Folds what the transcript gained, in file order.
    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for record in records {
            switch record {
            case .permissionMode(let mode):
                permissionMode = mode
            default:
                break
            }
        }
        background.apply(records)
    }
}
