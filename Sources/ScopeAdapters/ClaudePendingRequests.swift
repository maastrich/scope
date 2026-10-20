import Foundation
import ScopeCore

/// What a Claude Code session is waiting on the user for, with its content (`ClaudePendingRequest`), oldest first.
///
/// A permission is described by `PermissionRequest` the moment it is raised, but that hook is not the signal that
/// someone must act (spec §4.7): every other `PermissionRequest` hook fires with it and any of them may answer, and
/// auto mode's classifier may never show it. So a permission is kept *unconfirmed* until `permission_prompt` says
/// the dialog is really up — and only a `shown` request is ever displayed. A question or a plan is shown from its
/// `PreToolUse`; an MCP form from its `elicitation_dialog`.
///
/// A request goes at the first sign it was decided: its tool's `PostToolUse`, `PostToolUseFailure` or
/// `PermissionDenied` (matched on `tool_use_id`, else on the tool and its input — `PermissionRequest` carries no
/// id), an `ElicitationResult`, the turn moving on (a prompt, `Stop`, the transcript's `turn_duration`), the user's
/// own keystroke in the dialog (`userTyped`). Saying "No" in the dialog fires no hook at all; the turn's end is what
/// clears it then.
///
/// Equal values mean nothing a view shows moved: no clock in here beyond each request's `askedAt`.
public struct ClaudePendingRequests: Sendable, Equatable {
    /// Every request described and not yet decided, oldest first; shown or not.
    public private(set) var requests: [ClaudePendingRequest] = []

    public init(requests: [ClaudePendingRequest] = []) {
        self.requests = requests
    }

    /// The dialog on screen now: the oldest request that is up. Two stacked permissions are asked one after the other
    /// (`1 of 2`), in the order Claude Code described them.
    public var current: ClaudePendingRequest? { requests.first(where: \.shown) }

    /// Every request up, oldest first.
    public var shown: [ClaudePendingRequest] { requests.filter(\.shown) }

    /// How the thread waits while `current` is up: a permission waits for a permission, anything else for an answer.
    public var waitReason: WaitReason? {
        current.map { $0.kind == .permission ? .permission : .input }
    }

    /// Requests kept at most: a session that somehow never clears them must not grow without bound.
    static let limit = 20

    // MARK: Hooks

    public mutating func apply(_ facts: ClaudeHookFacts) {
        switch facts.event {
        case "PermissionRequest":
            // A question tool asks for permission to ask: its `PreToolUse` already holds the question.
            guard let tool = facts.toolName, !ClaudeQuestionTools.names.contains(tool) else { return }
            let request = ClaudePendingRequest.permission(facts)
            guard !requests.contains(where: { $0.id == request.id }) else { return }
            append(request)
        case "PreToolUse":
            guard let tool = facts.toolName, ClaudeQuestionTools.names.contains(tool) else { return }
            let request = ClaudePendingRequest.question(tool: tool, toolUseID: facts.toolUseID, input: facts.toolInput,
                                                        agentID: facts.agentID, agentType: facts.agentType, at: facts.at)
            requests.removeAll { $0.id == request.id }
            append(request)
        case "Notification":
            notification(facts.body["notification_type"]?.string, facts: facts)
        case "Elicitation":
            let request = ClaudePendingRequest.elicitation(facts)
            // The server's tool is running, so the permission it needed was given.
            if let server = request.mcpServer {
                requests.removeAll { $0.kind == .permission && $0.mcpServer == server }
            }
            append(request)
        case "ElicitationResult":
            removeElicitation(server: facts.body["mcp_server_name"]?.nonEmptyString)
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            resolve(tool: facts.toolName, toolUseID: facts.toolUseID, input: facts.toolInput)
        case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd":
            // The main turn moved on: nothing of it is still asked. A sub-agent's own stop only takes its requests.
            requests.removeAll()
        case "SubagentStop":
            if let agent = facts.agentID { requests.removeAll { $0.agentID == agent } }
        default:
            break
        }
    }

    private mutating func notification(_ type: String?, facts: ClaudeHookFacts) {
        switch type {
        case "permission_prompt":
            // Names no tool: it confirms the oldest permission still waiting to be. A question tool's own
            // `permission_prompt` finds none (its question is shown already).
            if let index = requests.firstIndex(where: { $0.kind == .permission && !$0.shown }) {
                requests[index].shown = true
            }
        case "elicitation_dialog", "elicitation_url_dialog":
            if let index = requests.firstIndex(where: { $0.kind == .elicitation && !$0.shown }) {
                requests[index].shown = true
            } else if !requests.contains(where: { $0.kind == .elicitation }) {
                // No `Elicitation` hook before it (an older settings file): what is asked is unknown, not that it is.
                var request = ClaudePendingRequest(id: "elicit-" + ClaudePendingRequest.digest("\(facts.at.timeIntervalSince1970)"),
                                                   kind: .elicitation, agentID: facts.agentID, askedAt: facts.at, shown: true)
                request.mode = type == "elicitation_url_dialog" ? "url" : "form"
                append(request)
            }
        case "elicitation_complete", "elicitation_response":
            removeElicitation(server: nil)
        default:
            break
        }
    }

    private mutating func append(_ request: ClaudePendingRequest) {
        requests.append(request)
        if requests.count > Self.limit { requests.removeFirst(requests.count - Self.limit) }
    }

    /// Drops the request a tool report is about: by `tool_use_id`, else by the tool and its exact input, else — when
    /// the report's input was cut on the wire (`…`), so it can differ from the request's — the oldest one for the
    /// same tool. Only then: the report of a request already answered at a key must not take the next one with it.
    mutating func resolve(tool: String?, toolUseID: String?, input: JSONValue?) {
        if let toolUseID, let index = requests.firstIndex(where: { $0.toolUseID == toolUseID }) {
            requests.remove(at: index)
            return
        }
        let id = "perm-" + ClaudePendingRequest.digest(ClaudePendingRequest.fingerprint(tool: tool, input: input))
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests.remove(at: index)
            return
        }
        guard let tool, input?.jsonString.contains("…") == true else { return }
        if let index = requests.firstIndex(where: { $0.tool == tool && $0.toolUseID == nil }) {
            requests.remove(at: index)
        }
    }

    private mutating func removeElicitation(server: String?) {
        if let index = requests.firstIndex(where: { $0.kind == .elicitation && (server == nil || $0.mcpServer == server) }) {
            requests.remove(at: index)
        }
    }

    // MARK: Transcript

    /// The transcript says when a question tool got its answer, and when the turn is over — the one trace a "No" in a
    /// permission dialog leaves.
    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for record in records {
            switch record {
            case .toolCall(let call):
                requests.removeAll { $0.toolUseID == call.id }
            case .turnDuration(let turn):
                // A transcript read from its start again (a relaunch, a resumed session) replays every turn's end:
                // only one written after a request was asked can have ended it.
                if let end = turn.at {
                    requests.removeAll { $0.askedAt <= end }
                } else {
                    requests.removeAll()
                }
            default:
                break
            }
        }
    }

    // MARK: The user's answer

    /// What a keystroke into the terminal did to the request on screen.
    public enum Keystroke: Sendable, Equatable {
        /// Not an answer to it.
        case none
        /// `1` in a permission dialog: always *Yes*.
        case approved
        /// Some other answer: another option, Return on the highlighted one, Esc.
        case answered
    }

    /// The user typed `bytes` into the terminal while `current` was up. A permission is decided by one key — a digit,
    /// Return, Esc — and its tool may then run for minutes before any hook says so; a single-choice question by its
    /// option's digit. A multiple choice, or several questions, take several keys: their `PostToolUse` follows the
    /// last one at once, so they are left to it.
    public mutating func userTyped(_ bytes: some Collection<UInt8>) -> Keystroke {
        guard let current, bytes.count == 1, let byte = bytes.first else { return .none }
        let digit = (0x31...0x39).contains(byte)
        switch current.kind {
        case .permission:
            guard digit || byte == 0x0d || byte == 0x1b else { return .none }
            requests.removeAll { $0.id == current.id }
            return byte == 0x31 ? .approved : .answered
        case .question:
            let single = current.questions.count == 1 && current.questions.first?.multiSelect == false
            guard (single && digit) || byte == 0x1b else { return .none }
            requests.removeAll { $0.id == current.id }
            return .answered
        case .plan, .elicitation:
            guard byte == 0x1b else { return .none }
            requests.removeAll { $0.id == current.id }
            return .answered
        }
    }

    /// The request is no longer asked (answered from Scope).
    public mutating func remove(id: String) {
        requests.removeAll { $0.id == id }
    }

    /// A permission described and not confirmed yet: what `ClaudeAgentsReport` is asked about.
    public var awaitsConfirmation: Bool {
        requests.contains { $0.kind == .permission && !$0.shown }
    }

    /// `PermissionRequest` described it and the session is waiting on a permission dialog right now (`claude agents`):
    /// shown without waiting for `permission_prompt`. `false` when there was nothing to confirm.
    /// Returns the id of the request confirmed, `nil` when there was nothing to confirm.
    @discardableResult
    public mutating func confirmPermission() -> String? {
        guard let index = requests.firstIndex(where: { $0.kind == .permission && !$0.shown }) else { return nil }
        requests[index].shown = true
        return requests[index].id
    }
}
