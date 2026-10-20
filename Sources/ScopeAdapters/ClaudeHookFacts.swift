import Foundation

/// Everything a Claude Code hook said, as the app keeps it: the hook's stdin JSON, clamped by `scope-hook` so it
/// always fits in the event (`HookEvent.hookKey`) and always parses — where `raw` is cut, and no longer parses, once a
/// tool's response is large.
///
/// The fields named here are the ones several features read (code.claude.com/docs/en/hooks); the rest of the
/// payload stays in `body`. Every one is optional: an older Claude Code, or a hook that does not carry it, reads as
/// absent. Built for any event, whether or not it moves the thread state — a background command reporting after its
/// turn is over is exactly what the background-work features want to see.
public struct ClaudeHookFacts: Sendable, Equatable {
    /// `hook_event_name`: `PostToolUse`, `Stop`, `PreCompact`, …
    public var event: String
    public var sessionID: String?
    /// `permission_mode`, on most events: `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`.
    public var permissionMode: String?
    /// `effort.level`, inside a tool context.
    public var effort: String?
    /// The sub-agent the hook fires in or about (`agent_id`, `agent_type`), and its own transcript
    /// (`agent_transcript_path`, `SubagentStop`).
    public var agentID: String?
    public var agentType: String?
    public var agentTranscriptPath: String?
    /// Tool hooks: `tool_name`, `tool_use_id`, `tool_input`, and on `PostToolUse` the structured `tool_response`.
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: JSONValue?
    public var toolResponse: JSONValue?
    /// `Stop` / `SubagentStop`: the background work still attached to the session (`background_tasks`, each
    /// `{id, type, status, description, …}`) and its scheduled prompts (`session_crons`). `nil` when the hook did not
    /// say (Claude Code before 2.1.145), which is not the same as an empty list.
    public var backgroundTasks: [JSONValue]?
    public var sessionCrons: [JSONValue]?
    /// The whole clamped payload.
    public var body: JSONValue
    /// When the app received it.
    public var at: Date

    public init(body: JSONValue, at: Date) {
        self.body = body
        self.at = at
        event = body["hook_event_name"]?.string ?? ""
        sessionID = body["session_id"]?.nonEmptyString
        permissionMode = body["permission_mode"]?.nonEmptyString
        effort = body["effort"]?["level"]?.nonEmptyString ?? body["effort"]?.nonEmptyString
        agentID = body["agent_id"]?.nonEmptyString
        agentType = body["agent_type"]?.nonEmptyString
        agentTranscriptPath = body["agent_transcript_path"]?.nonEmptyString
        toolName = body["tool_name"]?.nonEmptyString
        toolUseID = body["tool_use_id"]?.nonEmptyString
        toolInput = body["tool_input"].flatMap { $0.isNull ? nil : $0 }
        toolResponse = body["tool_response"].flatMap { $0.isNull ? nil : $0 }
        backgroundTasks = body["background_tasks"]?.array
        sessionCrons = body["session_crons"]?.array
    }

    /// The facts an event carries: its `hook` payload, else its `raw` stdin when that still parses. `nil` for an
    /// event that came from no Claude Code hook.
    public static func from(_ event: AdapterEvent) -> ClaudeHookFacts? {
        let body = event.payload[HookEvent.hookKey].flatMap { JSONValue(json: $0) }
            ?? event.raw.flatMap { JSONValue(json: $0) }
        guard let body, body["hook_event_name"]?.nonEmptyString != nil else { return nil }
        return ClaudeHookFacts(body: body, at: event.receivedAt)
    }

    // MARK: Wire

    /// Most bytes the clamped payload may take on the wire; the event as a whole stays under `scope-hook`'s own cap.
    public static let wireLimit = 48 * 1024

    /// Successive clamps tried until one fits `wireLimit`: generous first, then tight.
    static let clamps: [(stringLimit: Int, arrayLimit: Int, depth: Int)] = [(2000, 100, 8), (400, 40, 6), (120, 20, 4)]

    /// The hook's stdin JSON as `scope-hook` forwards it (`HookEvent.hookKey`): compact, strings and arrays bounded,
    /// `nil` when stdin is not a Claude Code hook payload or cannot be made to fit.
    public static func wirePayload(from stdin: Data) -> String? {
        guard let body = JSONValue(json: stdin), body["hook_event_name"]?.nonEmptyString != nil else { return nil }
        for clamp in clamps {
            let text = body.clamped(stringLimit: clamp.stringLimit, arrayLimit: clamp.arrayLimit, depth: clamp.depth).jsonString
            if text.utf8.count <= wireLimit { return text }
        }
        return nil
    }
}
