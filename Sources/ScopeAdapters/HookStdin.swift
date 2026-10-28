import Foundation

/// What `scope-hook` understands of a driver's own hook JSON (its stdin with `--stdin`).
///
/// Read: the driver's session id, lifted into `payload["session_id"]` so the app never parses `raw`; for
/// Claude Code's `Notification` hook the `notification_type`, which decides between `permission.requested` and
/// `input.requested`; the `tool_name` of a tool hook, so a permission request for a question tool counts as a
/// question; the `error` of `StopFailure`; where the driver is working — the folder of the file a tool just
/// touched, else the hook's `cwd`; what a tool call was about (`toolTarget`); and the session's `transcript_path`.
/// Everything else stays verbatim in `raw`.
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
    /// Claude Code `StopFailure`: what the error said beyond its code (`error_details`), when it says anything.
    public var errorDetails: String?
    /// Where the driver is working: the folder of the file its tool call names (`tool_input.file_path`,
    /// `notebook_path` or `path`, when absolute), else the hook's own `cwd`. A driver never reports a directory
    /// the way a shell does, so this is the only thing that says which repository of a task it is in.
    public var directory: String?
    /// The agent's answer at the end of its turn: Claude Code's `Stop` hook (`last_assistant_message`), Codex
    /// `notify` (`last-assistant-message`). What another agent wants when it asks what this one said — the
    /// terminal holds the same words, wrapped, redrawn and buried under spinners.
    public var lastAssistantMessage: String?
    /// Tool hooks: what the call was about, in one bounded line — the file, the first line of the command, the
    /// pattern, the URL, the sub-agent's description. Lifted here because `raw` is cut once a tool's response is
    /// large, and a cut `raw` no longer parses.
    public var toolTarget: String?
    /// Claude Code: the session's JSONL transcript, where token usage lives. Only the path; nothing reads it here.
    public var transcriptPath: String?
    /// What the driver is asking, in its own words: the questions of `AskUserQuestion`, the plan of `ExitPlanMode`,
    /// the message of a `Notification` hook when it is more than Claude Code's stock line.
    public var question: String?
    /// Claude Code `MessageDisplay`: the lines of the answer completed since the previous flush (`delta`), the id of
    /// the message being written (`message_id`, stable across its flushes) and whether this is its last flush
    /// (`final`). Display-only on Claude Code's side; here it is what the reading column shows while the agent writes.
    public var displayDelta: String?
    public var displayMessageID: String?
    public var displayFinal: Bool?
    /// `PostToolUse`: how long the call took (`duration_ms`).
    public var toolDurationMs: Int?
    /// Claude Code `SubagentStart` / `SubagentStop`: the sub-agent's own id (`agent_id`), the same on both.
    public var agentID: String?
    /// A status-line payload: its `rate_limits` object as compact JSON (`RateLimits.extract`), `nil` when absent.
    public var rateLimitsJSON: String?
    /// A status-line payload: the session's context window, model and driver version as compact JSON
    /// (`ContextWindowReport.extract`), `nil` when it says none of them.
    public var contextWindowJSON: String?
    /// A status-line payload: where the session works (`workspace.project_dir`, else `cwd`), where a project's own
    /// `.claude/settings*.json` would be.
    public var projectDirectory: String?

    public init(sessionID: String? = nil, notificationType: String? = nil, hookEventName: String? = nil,
                toolName: String? = nil, error: String? = nil, directory: String? = nil,
                lastAssistantMessage: String? = nil, toolTarget: String? = nil, transcriptPath: String? = nil,
                question: String? = nil, displayDelta: String? = nil, displayMessageID: String? = nil,
                displayFinal: Bool? = nil) {
        self.sessionID = sessionID
        self.notificationType = notificationType
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.error = error
        self.directory = directory
        self.lastAssistantMessage = lastAssistantMessage
        self.toolTarget = toolTarget
        self.transcriptPath = transcriptPath
        self.question = question
        self.displayDelta = displayDelta
        self.displayMessageID = displayMessageID
        self.displayFinal = displayFinal
    }

    /// `true` for a command-line argument that is the driver's hook JSON itself: Codex `notify` runs the
    /// configured program with the notification as its last argument, not on stdin.
    public static func isInlinePayload(_ argument: String) -> Bool {
        argument.drop(while: \.isWhitespace).first == "{"
    }

    /// Keys tried, in order, for the agent's last answer.
    public static let lastAssistantMessageKeys = ["last_assistant_message", "last-assistant-message"]

    /// Keys of `tool_input` that name the file a tool works on, in the order tried.
    public static let filePathKeys = ["file_path", "notebook_path", "path"]

    /// Most characters a tool target keeps; the rest becomes `…`.
    public static let toolTargetLimit = 120

    /// `tool_input` keys that say what a call is about, per tool. Grep and Glob also carry a `path` (the folder
    /// searched), so a single key order would name the folder instead of the pattern.
    public static let toolTargetKeys: [String: [String]] = [
        "Read": filePathKeys, "Edit": filePathKeys, "Write": filePathKeys, "MultiEdit": filePathKeys,
        "NotebookEdit": filePathKeys, "NotebookRead": filePathKeys,
        "Bash": ["command"], "BashOutput": ["bash_id"], "KillShell": ["shell_id"],
        "Grep": ["pattern"], "Glob": ["pattern"],
        "WebFetch": ["url"], "WebSearch": ["query"],
        "Task": ["description", "subagent_type"], "Agent": ["description", "subagent_type"],
        "Skill": ["skill", "command"], "SlashCommand": ["command"],
        "ExitPlanMode": ["plan"], "AskUserQuestion": ["question"],
    ]

    /// Keys tried for a tool missing from `toolTargetKeys` (MCP tools, tools newer than this build).
    public static let fallbackTargetKeys = ["file_path", "notebook_path", "command", "pattern", "url", "query",
                                            "description", "path", "name", "thread", "prompt"]

    /// The target of a call to `tool` with `input`: the first non-empty value among its keys, cut to its first
    /// non-empty line and to `toolTargetLimit` characters.
    public static func toolTarget(tool: String?, input: [String: Any]?) -> String? {
        guard var input else { return nil }
        // `AskUserQuestion` holds its questions in an array: the first one is what the user is being asked.
        if tool == "AskUserQuestion", let first = (input["questions"] as? [[String: Any]])?.first {
            input = first
        }
        let keys = tool.flatMap { toolTargetKeys[$0] } ?? fallbackTargetKeys
        for key in keys {
            guard let value = input[key] as? String else { continue }
            let line = value.split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard let line else { continue }
            return line.count > toolTargetLimit ? line.prefix(toolTargetLimit - 1) + "…" : line
        }
        return nil
    }

    /// `Notification` messages that only restate the event (`permission_prompt`, `idle_prompt`): a notification
    /// built from them says less than the agent's own last words.
    public static let stockMessagePrefixes = ["Claude needs your permission", "Claude is waiting for your input"]

    /// The question in a hook payload: each `questions[].question` of `AskUserQuestion`, one per line; the `plan` of
    /// `ExitPlanMode`; else a `Notification` message that is not a stock one.
    public static func question(tool: String?, input: [String: Any]?, message: String?) -> String? {
        func nonEmpty(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        switch tool {
        case "AskUserQuestion":
            let questions = (input?["questions"] as? [[String: Any]])?.compactMap { nonEmpty($0["question"] as? String) }
            if let questions, !questions.isEmpty { return questions.joined(separator: "\n") }
        case "ExitPlanMode":
            if let plan = nonEmpty(input?["plan"] as? String) { return plan }
        default:
            break
        }
        guard let message = nonEmpty(message), !stockMessagePrefixes.contains(where: message.hasPrefix) else { return nil }
        return message
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
        result.errorDetails = (object["error_details"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        result.lastAssistantMessage = lastAssistantMessageKeys.lazy.compactMap { object[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let input = object["tool_input"] as? [String: Any]
        result.toolTarget = toolTarget(tool: result.toolName, input: input)
        result.toolDurationMs = (object["duration_ms"] as? NSNumber).map(\.intValue)
        result.agentID = (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        result.transcriptPath = (object["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        result.rateLimitsJSON = RateLimits.extract(statusline: data)
        result.contextWindowJSON = ContextWindowReport.extract(statusline: data)
        let workspace = object["workspace"] as? [String: Any]
        result.projectDirectory = ((workspace?["project_dir"] as? String) ?? (object["cwd"] as? String))
            .flatMap { $0.hasPrefix("/") ? $0 : nil }
        result.question = question(tool: result.toolName, input: input, message: object["message"] as? String)
        if result.hookEventName == "MessageDisplay" {
            result.displayDelta = object["delta"] as? String
            result.displayMessageID = (object["message_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result.displayFinal = object["final"] as? Bool
        }
        let file = filePathKeys.lazy.compactMap { input?[$0] as? String }.first { $0.hasPrefix("/") }
        if let file {
            result.directory = URL(fileURLWithPath: file).deletingLastPathComponent().path
        } else if let cwd = object["cwd"] as? String, cwd.hasPrefix("/") {
            result.directory = cwd
        }
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
/// `notification`, which is resolved from stdin with `ClaudeNotificationMapping`, and `statusline`, Claude Code's
/// status-line command, which sends `limits.reported` when the payload carries `rate_limits` or a context window
/// and then runs the status line the user configured (`ClaudeStatusline`).
public enum HookCommandEvent: Sendable, Equatable {
    case fixed(HookEvent.Kind)
    /// Resolved from `notification_type` on stdin (`--stdin` is implied).
    case notification
    /// Resolved from `rate_limits` and `context_window` on stdin (`--stdin` is implied): `limits.reported`, or
    /// nothing to send.
    case statusline

    /// The command-line word for the derived event.
    public static let notificationWord = "notification"
    public static let statuslineWord = "statusline"

    public init?(word: String) {
        if word == Self.notificationWord {
            self = .notification
        } else if word == Self.statuslineWord {
            self = .statusline
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
        case .statusline: stdin.rateLimitsJSON == nil && stdin.contextWindowJSON == nil ? nil : .limitsReported
        }
    }

    /// `true` when stdin must be read even without `--stdin`.
    public var needsStdin: Bool { self == .notification || self == .statusline }

    /// Every accepted word, for the usage text.
    public static var allWords: [String] {
        HookEvent.Kind.allCases.map(\.rawValue) + [notificationWord, statuslineWord]
    }
}

/// What an agent last answered, and when its turn ended.
public struct AgentReply: Codable, Sendable, Equatable {
    public var text: String
    public var at: Date

    public init(text: String, at: Date) {
        self.text = text
        self.at = at
    }

    /// The answer carried by a `turn.ended` event, `nil` for any other event or a driver that reports none.
    public static func from(_ event: AdapterEvent) -> AgentReply? {
        guard event.kind == .turnEnded else { return nil }
        let text = event.payload[HookEvent.replyKey]
            ?? event.raw.flatMap { HookStdin.parse(Data($0.utf8)).lastAssistantMessage }
        return text.map { AgentReply(text: $0, at: event.receivedAt) }
    }
}
