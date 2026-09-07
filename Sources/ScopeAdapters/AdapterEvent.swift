import Foundation
import ScopeCore

/// App-side view of a `HookEvent`: the thread id is validated and typed, and the receipt time is stamped by
/// the app rather than trusted from the sender.
public struct AdapterEvent: Sendable, Equatable {
    /// The thread the event is about (already known to the app when it comes out of `HookSocketServer`).
    public var threadID: ThreadID
    /// The normalized event.
    public var kind: HookEvent.Kind
    /// Free-form `key=value` pairs from the hook command line.
    public var payload: [String: String]
    /// Raw stdin of the driver hook, if it was forwarded.
    public var raw: String?
    /// When the sender says it sent the event (may be `nil` or skewed; informational only).
    public var sentAt: Date?
    /// When the app received the event.
    public var receivedAt: Date

    public init(threadID: ThreadID, kind: HookEvent.Kind, payload: [String: String] = [:], raw: String? = nil,
                sentAt: Date? = nil, receivedAt: Date = .now) {
        self.threadID = threadID
        self.kind = kind
        self.payload = payload
        self.raw = raw
        self.sentAt = sentAt
        self.receivedAt = receivedAt
    }

    /// Builds the typed event from a wire event; `nil` when `thread` is not a well-formed `ThreadID`.
    public init?(_ event: HookEvent, receivedAt: Date = .now) {
        guard let threadID = ThreadID(rawValue: event.thread) else { return nil }
        self.init(threadID: threadID, kind: event.event, payload: event.payload, raw: event.raw,
                  sentAt: event.sentAt, receivedAt: receivedAt)
    }

    /// The `reason=` payload value, if the hook gave one (`input` or `permission`).
    public var reason: String? { payload[HookEvent.reasonKey] }
}
