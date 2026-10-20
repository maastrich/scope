import Foundation
import ScopeAdapters

/// A Claude Code thread's session as `scope list threads` and `scope_list` give it (`ThreadSummary.session`): the
/// permission mode and model it runs with now, its compactions, the MCP servers that failed or wait for
/// authentication. Only the servers in trouble: the whole roster is the app's Connectors card.
public struct ClaudeSessionSummary: Codable, Sendable, Equatable {
    public struct Compaction: Codable, Sendable, Equatable {
        /// `auto` or `manual`.
        public var trigger: String?
        public var preTokens: Int?
        public var postTokens: Int?
        public var durationMs: Int?
        public var at: Date?
    }

    public struct MCPServer: Codable, Sendable, Equatable {
        public var name: String
        /// `failed` or `needsAuth`.
        public var status: String
        /// A failure's code (`CONNECTION_CLOSED`, …) and message, bounded.
        public var code: String?
        public var error: String?
    }

    /// `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`.
    public var permissionMode: String?
    /// The model the session runs on now, after any `/model`: may differ from `ThreadSummary.model`, the one the
    /// thread was opened with.
    public var model: String?
    public var effort: String?
    /// `true` while a compaction runs.
    public var compacting: Bool?
    public var compactions: Int?
    public var lastCompaction: Compaction?
    /// The MCP servers that failed or wait for authentication; absent when none does.
    public var mcpServers: [MCPServer]?

    public init(permissionMode: String? = nil, model: String? = nil, effort: String? = nil, compacting: Bool? = nil,
                compactions: Int? = nil, lastCompaction: Compaction? = nil, mcpServers: [MCPServer]? = nil) {
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.compacting = compacting
        self.compactions = compactions
        self.lastCompaction = lastCompaction
        self.mcpServers = mcpServers
    }

    /// Most characters of a failure's message kept: Claude Code's can carry a whole stack.
    static let errorLimit = 200

    /// `nil` when the session said nothing worth a field yet.
    public static func make(_ session: ClaudeSession) -> ClaudeSessionSummary? {
        let troubled = session.mcpServers.servers.filter { $0.status == .failed || $0.status == .needsAuth }.map {
            MCPServer(name: $0.name, status: $0.status.rawValue, code: $0.errorCode,
                      error: $0.error.map { $0.count > errorLimit ? String($0.prefix(errorLimit - 1)) + "…" : $0 })
        }
        let last = session.compactions.last.map {
            Compaction(trigger: $0.trigger, preTokens: $0.preTokens, postTokens: $0.postTokens, durationMs: $0.durationMs, at: $0.at)
        }
        let summary = ClaudeSessionSummary(
            permissionMode: session.permissionMode, model: session.model.id, effort: session.effort,
            compacting: session.compactions.isRunning ? true : nil,
            compactions: session.compactions.count > 0 ? session.compactions.count : nil, lastCompaction: last,
            mcpServers: troubled.isEmpty ? nil : troubled)
        return summary == ClaudeSessionSummary() ? nil : summary
    }

    /// The `MODE` column: `plan`, `bypass`, … and nothing for the default mode.
    public var modeColumn: String { ClaudePermissionMode.short(permissionMode) ?? "" }

    /// What `scope list threads` adds after the activity, when there is something: `compacting`, `2 compactions`,
    /// `MCP failed: github, linear`.
    public var notes: [String] {
        var notes: [String] = []
        if compacting == true { notes.append("compacting") }
        if let compactions { notes.append(compactions == 1 ? "1 compaction" : "\(compactions) compactions") }
        let failed = (mcpServers ?? []).filter { $0.status == "failed" }.map(\.name)
        if !failed.isEmpty { notes.append("MCP failed: " + failed.joined(separator: ", ")) }
        let auth = (mcpServers ?? []).filter { $0.status == "needsAuth" }.map(\.name)
        if !auth.isEmpty { notes.append("MCP needs auth: " + auth.joined(separator: ", ")) }
        return notes
    }
}
