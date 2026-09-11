import Foundation
import ScopeCore

/// The wire format written by `scope-hook` on the unix socket: one JSON object per connection.
///
/// ```json
/// { "thread" : "3f9a2c17be04", "event" : "input.requested",
///   "payload" : { "reason" : "permission", "tool" : "Bash" },
///   "sentAt" : "2026-09-07T11:41:02.771Z",
///   "raw" : "{\"session_id\":\"…\",\"hook_event_name\":\"Notification\"}" }
/// ```
///
/// `thread` stays a plain string here: the hook binary forwards whatever `SCOPE_THREAD` contains and the
/// app decides whether it names a known thread (see `HookSocketServer`).
public struct HookEvent: Codable, Sendable, Equatable {
    /// The normalized driver events. Raw values are the strings accepted on the `scope-hook` command
    /// line and written on the wire.
    ///
    /// The state-changing events come from spec §4.7, plus `turn.failed` for a turn that ended on an error
    /// (its code in `payload["error"]`). `session.started` is informational: it never moves the thread state and
    /// only exists so an adapter can hand over the driver's session id (`payload["session_id"]`) as soon as the
    /// driver starts, before any turn.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case turnStarted = "turn.started"
        case turnEnded = "turn.ended"
        case turnFailed = "turn.failed"
        case inputRequested = "input.requested"
        case permissionRequested = "permission.requested"
        case threadEnded = "thread.ended"
        case sessionStarted = "session.started"

        /// `true` for the events that move the thread state (everything but `session.started`).
        public var changesState: Bool { self != .sessionStarted }
    }

    /// Value of `SCOPE_THREAD` in the driver's environment.
    public var thread: String
    /// The normalized event.
    public var event: Kind
    /// Free-form `key=value` pairs given on the hook command line (`reason`, `tool`, …).
    public var payload: [String: String]
    /// When the hook sent the event; `nil` when the sender did not say.
    public var sentAt: Date?
    /// Raw stdin of the driver hook (`--stdin`), kept verbatim for adapters that want to dig into it.
    public var raw: String?

    public init(thread: String, event: Kind, payload: [String: String] = [:], sentAt: Date? = .now, raw: String? = nil) {
        self.thread = thread
        self.event = event
        self.payload = payload
        self.sentAt = sentAt
        self.raw = raw
    }
}

extension HookEvent {
    /// Payload key under which `scope-hook` forwards a `reason=` argument (`input` or `permission`).
    public static let reasonKey = "reason"

    /// Payload key saying where a derived event comes from: `notification` for one `scope-hook` derived from
    /// Claude Code's `Notification` hook (see `ThreadStateMachine.next(_:on:)`).
    public static let viaKey = "via"
    public static let viaNotification = "notification"

    /// Payload key under which `scope-hook` forwards the error code of a failed turn (`rate_limit`, …).
    public static let errorKey = "error"

    /// Payload key under which `scope-hook` forwards the driver's own session id (lifted from the hook's
    /// stdin JSON, or given as `session_id=`). `ThreadSession` stores it as `ThreadRecord.resumeID`.
    public static let sessionIDKey = "session_id"

    /// Encodes the event as the wire JSON (sorted keys, ISO-8601 with fractional seconds).
    public func encoded() throws -> Data {
        try JSONStore.makeEncoder(fractionalSeconds: true).encode(self)
    }

    /// Decodes one wire message. `sentAt` accepts ISO-8601 dates with or without fractional seconds so a
    /// hand-written `nc -U` message is as good as one from `scope-hook`.
    public static func decode(_ data: Data) throws -> HookEvent {
        try JSONStore.makeDecoder(fractionalSeconds: true).decode(HookEvent.self, from: data)
    }
}
