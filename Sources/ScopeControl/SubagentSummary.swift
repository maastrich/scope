import Foundation
import ScopeAdapters

/// One sub-agent of a Claude Code thread, as `scope list threads`, `thread read` and `thread wait` carry it
/// (`ClaudeSubagents.Agent`): what it is, how it stands, how long it ran and what it consumed.
public struct SubagentSummary: Codable, Sendable, Equatable {
    /// Claude Code's `agentId`.
    public var id: String
    /// `general-purpose`, `Explore`, a custom agent's name.
    public var type: String?
    public var description: String?
    /// `running`, `completed`, `failed`, `stopped`, `interrupted` (the session ended before it reported).
    public var state: String
    /// Launched in the background: the thread goes on while it runs.
    public var background: Bool?
    public var model: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// How long it ran, or has been running.
    public var seconds: Int?
    public var tokens: Int?
    public var toolUses: Int?
    /// 1 for a sub-agent of the thread's session, 2 for one of its own, …
    public var depth: Int?
    /// The worktree it ran in (`isolation: worktree`).
    public var worktree: String?
    /// The start of its report, `thread read` only. Written by an agent: untrusted.
    public var result: String?

    /// Characters of a report a reader gets.
    public static let resultLimit = 600

    public init(_ agent: ClaudeSubagents.Agent, now: Date, alive: Bool = true, withResult: Bool = false) {
        id = agent.agentID ?? agent.id
        type = agent.type
        description = agent.description
        state = agent.state(alive: alive).rawValue
        background = agent.background
        model = agent.model
        startedAt = agent.startedAt
        endedAt = agent.endedAt
        seconds = agent.duration(now: now).map { Int($0.rounded()) }
        tokens = agent.tokens
        toolUses = agent.toolUses
        depth = agent.depth
        worktree = agent.worktreePath
        if withResult, let text = agent.result {
            let cut = text.count > Self.resultLimit ? String(text.prefix(Self.resultLimit - 1)) + "…" : text
            result = ThreadTranscript.defused(cut)
        }
    }

    /// `running · Explore · Find the auth flow · 2m 10s · 51k tokens · 17 tools`.
    public var line: String {
        var parts = [state]
        if let type { parts.append(type) }
        if let description { parts.append(description) }
        if let seconds { parts.append(SubagentList.duration(seconds)) }
        if let tokens { parts.append("\(TokenUsageText.compact(tokens)) tokens") }
        if let toolUses { parts.append("\(toolUses) tool\(toolUses == 1 ? "" : "s")") }
        if background == true, state == ClaudeSubagents.State.running.rawValue { parts.append("background") }
        return parts.joined(separator: " · ")
    }
}

/// Which of a thread's sub-agents an answer carries, and how a line counts them.
public enum SubagentList {
    /// Finished sub-agents `scope list threads` and `thread wait` carry beside the running ones: the latest.
    public static let recent = 5

    /// Every running sub-agent and the `recent` last to finish, oldest launch first; every one kept when `recent` is
    /// `nil`. `nil` for a thread that launched none, so the field stays out of the answer.
    public static func summaries(_ subagents: ClaudeSubagents, now: Date, alive: Bool, recent: Int? = recent,
                                 withResults: Bool = false) -> [SubagentSummary]? {
        guard !subagents.agents.isEmpty else { return nil }
        var kept = subagents.agents
        if let recent {
            let finished = kept.filter { !$0.state(alive: alive).isRunning }.suffix(recent).map(\.id)
            kept = kept.filter { $0.state(alive: alive).isRunning || finished.contains($0.id) }
        }
        return kept.map { SubagentSummary($0, now: now, alive: alive, withResult: withResults) }
    }

    /// `2 running · 5 done` for a table column; empty without any.
    public static func column(_ summaries: [SubagentSummary]?) -> String {
        guard let summaries, !summaries.isEmpty else { return "" }
        let running = summaries.filter { $0.state == ClaudeSubagents.State.running.rawValue }.count
        let done = summaries.count - running
        return [running > 0 ? "\(running) running" : nil, done > 0 ? "\(done) done" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// `45s`, `2m 10s`, `1h 05m`.
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h \(String(format: "%02d", seconds % 3600 / 60))m"
    }
}
