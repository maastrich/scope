import Foundation

/// Restart Session: the thread's `claude` process goes and a new one picks the same conversation back up
/// (`--resume <session-id>`, same cwd, model and Scope settings), so new MCP servers, settings, skills or a new
/// Claude Code version load without losing the context. A Relaunch that starts from a running thread.
///
/// Only for Claude Code: its session id is what the hooks capture, and its resume is what the bundled profiles
/// declare. The rules are here; `AppModel.restartSession` does the stopping and the starting.
public enum ThreadRestart {
    /// Why a thread cannot restart its session. `reason` is what the menu item and the CLI say.
    public enum Unavailable: Sendable, Equatable {
        /// Another driver: a shell, Codex, Cursor.
        case notClaude
        /// Claude Code has not reported a session yet (no `SessionStart` hook): nothing to resume.
        case noSession

        public var reason: String {
            switch self {
            case .notClaude: "only Claude Code threads restart their session"
            case .noSession: "no Claude Code session yet"
            }
        }

        /// The journal's `cause`.
        public var token: String {
            switch self {
            case .notClaude: "not-claude"
            case .noSession: "no-session"
            }
        }
    }

    /// `nil` when the thread can restart. A profile that would start a fresh session instead — no `resume` argv —
    /// counts as having no session: a restart that loses the conversation is not one.
    public static func unavailable(profile: DriverProfile, resumeID: String?) -> Unavailable? {
        guard isClaude(profile) else { return .notClaude }
        guard resumeMode(profile: profile, resumeID: resumeID) == .resume else { return .noSession }
        return nil
    }

    /// The thread is a Claude Code one: the menu shows the item at all.
    public static func isClaude(_ profile: DriverProfile) -> Bool {
        profile.adapter?.kind == ClaudeHooksAdapter.kind
    }

    /// The launch that follows the kill. Always `.resume` for a thread that may restart; `.launch` only for one that
    /// may not, which `AppModel` never starts.
    public static func resumeMode(profile: DriverProfile, resumeID: String?) -> LaunchMode {
        LaunchMode.relaunch(profile: profile, resumeID: resumeID)
    }

    /// The turn in progress would be cut short: the user is asked, an agent has to say `force`. A turn waiting on a
    /// permission is still open (`inTurn`) though nothing runs (`working`).
    public static func interruptsTurn(inTurn: Bool, working: Bool) -> Bool {
        inTurn || working
    }

    /// How long Claude Code is given to stop its turn after Esc before the process is hung up.
    public static let interruptGrace: Duration = .milliseconds(600)
    /// SIGHUP, then SIGKILL after this if the same pid is still there.
    public static let killAfter: Double = 2
    /// How long the restart waits for the process to be gone. Past it nothing is started: two `claude` on one
    /// session would write the same transcript.
    public static let exitTimeout: Duration = .seconds(5)
    /// An agent restarting its own thread is answered first; the restart waits for its turn to end, at most this long.
    public static let selfRestartTimeout: Duration = .seconds(60)

    /// Typed to an agent that restarted its own session once the new one is up: its turn ended with the call, and
    /// nothing else would tell it to go on. Not `InterruptedTurn.message`: Scope did not restart.
    public static let selfRestartNote = "[Scope: your Claude Code session was restarted as you asked (scope_thread_restart): "
        + "MCP servers, settings and skills are loaded again and the conversation is the same. Carry on where you left off.]"
}
