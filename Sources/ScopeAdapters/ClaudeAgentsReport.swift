import Foundation

/// What `claude agents --json` (Claude Code ≥ 2.1.145) says of the sessions alive on this machine: each one's
/// `sessionId`, `pid`, `status` (`busy`, `waiting`, `idle`) and, while it waits, `waitingFor` (`permission prompt`,
/// `input needed`, `dialog open`…).
///
/// Read once, a second after a `PermissionRequest` nobody decided: the session says at once that its permission dialog
/// is up, where the `permission_prompt` notification waits about six seconds. Then each second until that
/// notification comes, since another hook may still answer: a few processes (~0.2 s each) per permission left
/// undecided, never more. Parsed tolerantly: an entry without a session id, a key that moved, output that is
/// not JSON read as nothing.
public struct ClaudeAgentsReport: Sendable, Equatable {
    public struct Session: Sendable, Equatable {
        public var sessionID: String
        public var pid: Int?
        public var status: String?
        public var waitingFor: String?
    }

    public var sessions: [Session]

    /// The argv that asks.
    public static let argv = ["claude", "agents", "--json"]

    /// How long a `PermissionRequest` is left to the other hooks and to auto mode before asking, and between two
    /// checks after that.
    public static let settle: Duration = .seconds(1)
    /// Checks after a confirmation, until `permission_prompt` (about six seconds into the dialog) takes over: the
    /// dialog is up while a companion's own `PermissionRequest` hook still decides, and it may answer in that time.
    public static let followUps = 5

    public init(sessions: [Session] = []) {
        self.sessions = sessions
    }

    public init(json: some DataProtocol) {
        let entries = JSONValue(json: json)?.array ?? []
        sessions = entries.compactMap { entry in
            guard let id = entry["sessionId"]?.nonEmptyString else { return nil }
            return Session(sessionID: id, pid: entry["pid"]?.int, status: entry["status"]?.nonEmptyString,
                           waitingFor: entry["waitingFor"]?.nonEmptyString)
        }
    }

    /// `true` when session `sessionID` is waiting on a permission dialog right now.
    public func waitsOnPermission(sessionID: String) -> Bool {
        sessions.contains { $0.sessionID == sessionID && $0.status == "waiting" && $0.waitingFor?.contains("permission") == true }
    }
}
