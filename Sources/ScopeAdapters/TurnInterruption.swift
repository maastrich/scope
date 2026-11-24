import Foundation

/// Why a turn that did not end on its own was cut, in the word the event journal keeps (`turn.interrupted`).
///
/// 110 interruptions of 03/11–18/11 were journaled `unknown`: no message of Scope's, no keystroke seen since the turn
/// began. Something still happened last in that thread — a permission denied, a `StopFailure`, a sub-agent stopping —
/// and that is what the cause now names, `after:<hook>`, so the next analysis can tell these apart.
public enum TurnInterruption {
    public static let unknown = "unknown"
    public static let typed = "typed"

    /// The cause of an interrupted turn, most certain first: what the session knows it did (`sent`, `esc`, `stuck`,
    /// …), a prompt the user typed since the turn began, else the last hook seen before the cut. `unknown` is left
    /// for a thread no hook ever spoke for.
    public static func cause(known: String?, typed: Bool, lastHook: String?) -> String {
        if let known { return known }
        if typed { return Self.typed }
        return lastHook.map { "after:\($0)" } ?? unknown
    }

    /// The name an event goes by in a cause: the Claude Code hook behind it (`StopFailure` → `stop-failure`), else
    /// the normalized event (`turn.started`). `nil` for the status line, which is no hook and comes with every
    /// message, and for a name that would not survive the journal. Never anything the hook carried: tool names and
    /// reasons can name servers and paths.
    public static func hookName(of event: AdapterEvent) -> String? {
        guard event.kind != .limitsReported else { return nil }
        let name = ClaudeHookFacts.from(event).map { kebab($0.event) } ?? event.kind.rawValue
        // `after:` and the name together must fit a journal token (64).
        guard !name.isEmpty, name.count <= 48, name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// `PostToolUseFailure` → `post-tool-use-failure`.
    static func kebab(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty, out.last != "-" { out.append("-") }
            out.append(contentsOf: character.lowercased())
        }
        return out
    }
}
