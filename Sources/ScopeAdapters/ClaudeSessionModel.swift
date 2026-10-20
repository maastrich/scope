import Foundation

/// The model a Claude Code session runs on now: what `SessionStart` said it started with (a resume says it too), and
/// every `/model` since (`PostModelSwitch`). Not the model the thread was opened with (`ThreadRecord.model`), which
/// the user may have switched away from.
///
/// The transcript's `message.model` is not read: the assistant lines that carry it are most of the file, and the
/// tail skips them undecoded.
public struct ClaudeSessionModel: Sendable, Equatable {
    /// `claude-opus-5-5`, `opus[1m]`, …: as Claude Code names it.
    public private(set) var id: String?
    /// The one before the last switch.
    public private(set) var previous: String?

    public init() {}

    public mutating func apply(_ facts: ClaudeHookFacts) {
        // A sub-agent runs on its own model.
        guard facts.agentID == nil else { return }
        let next: String? = switch facts.event {
        case "SessionStart": facts.body["model"]?.nonEmptyString ?? facts.body["model"]?["id"]?.nonEmptyString
        case "PostModelSwitch": facts.body["to_model"]?.nonEmptyString
        default: nil
        }
        guard let next, next != id else { return }
        if facts.event == "PostModelSwitch" { previous = facts.body["from_model"]?.nonEmptyString ?? id }
        id = next
    }
}

/// How a permission mode reads: `Plan mode`, `Accepting edits`, … `nil` for the default mode, which goes unsaid.
public enum ClaudePermissionMode {
    public static func label(_ mode: String?) -> String? {
        switch mode {
        case nil, "", "default": nil
        case "plan": "Plan mode"
        case "acceptEdits": "Accepting edits"
        case "auto": "Auto mode"
        case "dontAsk": "Don't ask"
        case "bypassPermissions": "Bypassing permissions"
        case let other?: other
        }
    }

    /// The short form a table column takes: `plan`, `accept edits`, `auto`, `bypass`.
    public static func short(_ mode: String?) -> String? {
        switch mode {
        case nil, "", "default": nil
        case "acceptEdits": "accept edits"
        case "bypassPermissions": "bypass"
        case "dontAsk": "don't ask"
        case let other?: other
        }
    }
}
