import Foundation
import ScopeAdapters
import ScopeCore

/// The activity line of a detailed sidebar row: what the agent is doing, in words — `Editing TaskTopic.swift`,
/// `Running swift test`, `Searching "topic"` while it works, what it asks while it waits, `Finished` once its turn
/// is over. `scope list` keeps the terser `ThreadActivityLine`.
///
/// The time is not in `text`: a row draws `since` itself, so ticking the clock redraws a caption and nothing else.
public struct ThreadActivityHeadline: Sendable, Equatable {
    public var text: String
    /// What `text` shortened — the full path, the whole command, the reply's first line — for the row's help.
    public var detail: String?
    /// When the thing `text` reports happened, for a `· 3m ago` after it; `nil` while it is still going on.
    public var since: Date?
    /// A finished turn's reply, first line: what `showing(.reply)` puts in place of `Finished`.
    public var reply: String?

    public init(text: String, detail: String? = nil, since: Date? = nil, reply: String? = nil) {
        self.text = text
        self.detail = detail
        self.since = since
        self.reply = reply
    }

    /// The line as the preference wants a finished turn told. A thread keeps the `.elapsed` one, so changing the
    /// preference redraws its rows without touching any thread.
    public func showing(_ finished: FinishedThreadLine) -> ThreadActivityHeadline {
        guard finished == .reply, let reply else { return self }
        return ThreadActivityHeadline(text: reply, detail: reply, since: since, reply: reply)
    }

    /// `nil` when there is nothing better than what a row says without it: an exited thread, one that never
    /// reported anything, one idle after a wait was dismissed.
    public static func make(_ activity: ThreadActivity, state: ThreadState,
                            finished: FinishedThreadLine = .elapsed) -> ThreadActivityHeadline? {
        make(activity, state: state)?.showing(finished)
    }

    private static func make(_ activity: ThreadActivity, state: ThreadState) -> ThreadActivityHeadline? {
        switch state {
        case .running:
            // A tool from before this turn says what the agent did last time, not what it is doing.
            if let tool = activity.lastTool, tool.at >= activity.turnStartedAt ?? .distantPast {
                let phrase = ToolPhrase(tool)
                return ThreadActivityHeadline(text: phrase.gerund, detail: phrase.detail)
            }
            return ThreadActivityHeadline(text: "Working…")
        case .waiting(let reason):
            if let request = activity.pendingRequest {
                // A question reads best as itself; a permission as what the agent asks to do.
                if request.name == "AskUserQuestion", let question = request.target, !question.isEmpty {
                    return ThreadActivityHeadline(text: question, detail: question)
                }
                let phrase = ToolPhrase(request)
                let question = ClaudeQuestionTools.names.contains(request.name)
                return ThreadActivityHeadline(text: question ? phrase.gerund : phrase.request, detail: phrase.detail)
            }
            // A question asked in prose ends the turn; the driver only says later that it is waiting on it.
            if reason == .input, let reply = activity.lastReply, let line = lastLine(reply.text) {
                return ThreadActivityHeadline(text: line, detail: line)
            }
            return ThreadActivityHeadline(text: reason == .input ? "Waiting for your answer" : "Waiting for your permission")
        case .done, .failed, .idle:
            guard let turn = activity.turns.last else { return nil }
            let reply = activity.lastReply.flatMap { $0.at >= turn.startedAt ?? turn.endedAt ? firstLine($0.text) : nil }
            switch turn.outcome {
            case .ended:
                return ThreadActivityHeadline(text: "Finished", detail: reply, since: turn.endedAt, reply: reply)
            case .failed:
                return ThreadActivityHeadline(text: turn.error.map { "Failed (\($0))" } ?? "Failed", since: turn.endedAt)
            case .interrupted:
                return ThreadActivityHeadline(text: "Interrupted", since: turn.endedAt)
            case .exited:
                return ThreadActivityHeadline(text: "Stopped mid-turn", since: turn.endedAt)
            case .inputRequested, .permissionRequested:
                return nil
            }
        case .exited:
            return nil
        }
    }

    /// `just now`, `42s ago`, `2m ago`, `3h ago`, `5d ago`: `ThreadActivityLine`'s clock.
    public static func ago(_ date: Date, now: Date) -> String {
        ThreadActivityLine.ago(date, now: now)
    }

    static func firstLine(_ text: String) -> String? {
        lines(text).first
    }

    static func lastLine(_ text: String) -> String? {
        lines(text).last
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "…" }
    }
}

/// One tool call in words, two ways: what the agent is doing (`Editing App.swift`) and what it asks to do
/// (`Asks to edit App.swift`).
struct ToolPhrase: Equatable {
    var gerund: String
    var request: String
    /// The target in full, when the phrase shortened it.
    var detail: String?

    /// How a tool's target reads in a phrase.
    private enum Object {
        /// A file: its last component.
        case path
        /// A shell command: as is, without a leading `cd … &&`.
        case command
        /// A pattern or a query: in quotes.
        case quoted
        /// A URL: its host.
        case host
        /// As given.
        case plain
        /// Not shown.
        case none
    }

    /// Gerund, infinitive, and how the target reads, per Claude Code tool.
    private static let table: [String: (String, String, Object)] = [
        "Read": ("Reading", "read", .path), "NotebookRead": ("Reading", "read", .path),
        "Edit": ("Editing", "edit", .path), "MultiEdit": ("Editing", "edit", .path),
        "NotebookEdit": ("Editing", "edit", .path), "Write": ("Writing", "write", .path),
        "Bash": ("Running", "run", .command),
        "BashOutput": ("Reading a command's output", "read a command's output", .none),
        "KillShell": ("Stopping a command", "stop a command", .none),
        "Grep": ("Searching", "search for", .quoted), "Glob": ("Looking for", "look for", .quoted),
        "WebFetch": ("Fetching", "fetch", .host), "WebSearch": ("Searching the web for", "search the web for", .quoted),
        "Task": ("Delegating:", "delegate:", .plain), "Agent": ("Delegating:", "delegate:", .plain),
        "Skill": ("Using the skill", "use the skill", .plain), "SlashCommand": ("Running", "run", .plain),
        "TodoWrite": ("Updating its plan", "update its plan", .none),
        "ExitPlanMode": ("Proposing a plan", "propose a plan", .none),
        "AskUserQuestion": ("Asking you a question", "ask you a question", .none),
    ]

    init(_ tool: ThreadActivity.Tool) {
        let target = tool.target.flatMap { $0.isEmpty ? nil : $0 }
        let (gerund, infinitive, object): (String, String, Object)
        if let known = Self.table[tool.name] {
            (gerund, infinitive, object) = known
        } else if let mcp = Self.mcpTool(tool.name) {
            // `mcp__scope__scope_thread_wait`: the tool's own name says more than the server's.
            (gerund, infinitive, object) = ("Using \(mcp)", "use \(mcp)", .none)
        } else {
            (gerund, infinitive, object) = ("Using \(tool.name)", "use \(tool.name)", .none)
        }
        let shown: String? = switch (object, target) {
        case (.none, _), (_, nil): nil
        case (.path, let target?): Self.lastComponent(target)
        case (.command, let target?): Self.command(target)
        case (.quoted, let target?): "\"\(target)\""
        case (.host, let target?): URL(string: target)?.host() ?? target
        case (.plain, let target?): target
        }
        self.gerund = [gerund, shown].compactMap { $0 }.joined(separator: " ")
        request = "Asks to " + [infinitive, shown].compactMap { $0 }.joined(separator: " ")
        // The help repeats the target only when the line does not already show all of it.
        detail = target.flatMap { $0 == shown || "\"\($0)\"" == shown ? nil : $0 }
    }

    /// The tool part of an MCP tool name, `nil` for any other.
    static func mcpTool(_ name: String) -> String? {
        let parts = name.split(separator: "__", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "mcp", !parts[2...].joined(separator: "__").isEmpty else { return nil }
        return parts[2...].joined(separator: "__")
    }

    static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    /// `cd Sources && swift test` reads as `swift test`: where it runs is in the row already.
    static func command(_ command: String) -> String {
        var rest = Substring(command)
        while rest.hasPrefix("cd "), let range = rest.range(of: " && ") {
            rest = rest[range.upperBound...]
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? command : trimmed
    }
}
