import Foundation

/// What `scope-hook` understands of a driver's own hook JSON (its stdin with `--stdin`).
///
/// Read: the driver's session id, lifted into `payload["session_id"]` so the app never parses `raw`; for
/// Claude Code's `Notification` hook the `notification_type`, which decides between `permission.requested` and
/// `input.requested`; the `tool_name` of a tool hook, so a permission request for a question tool counts as a
/// question; and the `error` of `StopFailure`. Everything else stays verbatim in `raw`.
public struct HookStdin: Sendable, Equatable {
    /// `session_id` (Claude Code, Cursor) or `thread-id` (Codex `notify`), whichever is present.
    public var sessionID: String?
    /// Claude Code `Notification` hooks: `notification_type` (`permission_prompt`, `idle_prompt`, …).
    public var notificationType: String?
    /// The driver's own event name when it says it (`hook_event_name` for Claude Code, `type` for Codex).
    public var hookEventName: String?
    /// Tool hooks (`PreToolUse`, `PermissionRequest`, …): the tool the driver is about to call.
    public var toolName: String?
    /// Claude Code `StopFailure`: the error code (`rate_limit`, `overloaded`, `billing_error`, …).
    public var error: String?

    public init(sessionID: String? = nil, notificationType: String? = nil, hookEventName: String? = nil,
                toolName: String? = nil, error: String? = nil) {
        self.sessionID = sessionID
        self.notificationType = notificationType
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.error = error
    }

    /// Keys tried, in order, for the session id.
    public static let sessionIDKeys = ["session_id", "thread-id", "thread_id"]

    /// Parses the stdin JSON. Anything that is not a JSON object (empty stdin, plain text) yields an empty value:
    /// a driver hook must never fail because its payload changed shape.
    public static func parse(_ data: Data) -> HookStdin {
        guard !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return HookStdin() }
        var result = HookStdin()
        for key in sessionIDKeys {
            if let value = object[key] as? String, !value.isEmpty {
                result.sessionID = value
                break
            }
        }
        result.notificationType = object["notification_type"] as? String
        result.hookEventName = (object["hook_event_name"] as? String) ?? (object["type"] as? String)
        result.toolName = object["tool_name"] as? String
        result.error = object["error"] as? String
        return result
    }
}

/// How Claude Code's `Notification` hook maps onto the normalized events.
///
/// `notification_type` values verified against the hooks reference (code.claude.com/docs/en/hooks):
/// `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`,
/// `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`,
/// `quota_auto_resume_*`. Only the ones that mean "someone must act" produce an event.
public enum ClaudeNotificationMapping {
    /// Types that mean the driver is waiting for a permission decision.
    public static let permissionTypes: Set<String> = ["permission_prompt"]
    /// Types that mean the driver is waiting for the user to type something.
    ///
    /// `idle_prompt` is deliberately left out: Claude Code sends it about a minute after *any* answer the user
    /// has not replied to, so it turned every finished thread into one that looked like it was asking a question.
    /// `Stop` already says the turn is over (`done`); a real question arrives as a question tool (see
    /// `ClaudeQuestionTools`) or an elicitation dialog.
    public static let inputTypes: Set<String> = ["agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"]

    /// The `Notification` matcher that selects exactly the types this mapping turns into events.
    public static var matcher: String {
        (permissionTypes.sorted() + inputTypes.sorted()).joined(separator: "|")
    }

    /// `permission.requested`, `input.requested`, or `nil` when the notification is not about waiting on someone.
    /// An unknown or absent type counts as `input.requested`: a notification is a request for attention by
    /// default, and the matcher in the settings file already filters the informational ones out.
    public static func kind(for notificationType: String?) -> HookEvent.Kind? {
        guard let notificationType, !notificationType.isEmpty else { return .inputRequested }
        if permissionTypes.contains(notificationType) { return .permissionRequested }
        if inputTypes.contains(notificationType) { return .inputRequested }
        return nil
    }
}

/// Claude Code tools that put a question to the user and wait for the answer. Their `PreToolUse` hook is how a
/// thread learns it is being asked something; the answer comes back as their `PostToolUse` (`turn.started`).
public enum ClaudeQuestionTools {
    public static let names: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// The `PreToolUse` matcher that selects exactly these tools.
    public static var matcher: String { names.sorted().joined(separator: "|") }
}

/// The event names `scope-hook` accepts on its command line: every `HookEvent.Kind` raw value plus
/// `notification`, which is resolved from stdin with `ClaudeNotificationMapping`.
public enum HookCommandEvent: Sendable, Equatable {
    case fixed(HookEvent.Kind)
    /// Resolved from `notification_type` on stdin (`--stdin` is implied).
    case notification

    /// The command-line word for the derived event.
    public static let notificationWord = "notification"

    public init?(word: String) {
        if word == Self.notificationWord {
            self = .notification
        } else if let kind = HookEvent.Kind(rawValue: word) {
            self = .fixed(kind)
        } else {
            return nil
        }
    }

    /// The wire event for `stdin`; `nil` means "nothing to send" (a notification nobody has to act on).
    /// A permission request for a question tool is a question: approving it *is* answering.
    public func resolve(stdin: HookStdin) -> HookEvent.Kind? {
        switch self {
        case .fixed(.permissionRequested) where stdin.toolName.map(ClaudeQuestionTools.names.contains) == true:
            .inputRequested
        case .fixed(let kind): kind
        case .notification: ClaudeNotificationMapping.kind(for: stdin.notificationType)
        }
    }

    /// `true` when stdin must be read even without `--stdin`.
    public var needsStdin: Bool { self == .notification }

    /// Every accepted word, for the usage text.
    public static var allWords: [String] {
        HookEvent.Kind.allCases.map(\.rawValue) + [notificationWord]
    }
}
