import Foundation

/// The MCP servers of a Claude Code session and how each one stands: still connecting, failed (with Claude Code's
/// message and code), waiting for authentication, or connected.
///
/// Claude Code never says a server is connected. It reports the ones still pending, failed or needing
/// authentication (`deferred_tools_delta`, as a snapshot of each list it carries) and lists the tools that became
/// available; "connected" is Scope's inference from that — the server's tools were listed, one was called, or the
/// server is known and no longer in any list — and `Server.isInferred` says so. The roster is the union of what the
/// deltas named, what the configuration declares (`ClaudeMCPConfig`: names and transports only) and the servers
/// whose tools were called. Before the first delta, nothing is claimed about a declared server: `.unknown`.
///
/// Servers are keyed by the name Claude Code puts in tool names (`MCPServerKey`): `claude.ai Linear` reports as
/// itself but calls as `mcp__claude_ai_Linear__…`.
public struct ClaudeMCPServers: Sendable, Equatable {
    /// Where a server is declared: Claude Code's scopes (`user` in `~/.claude.json`, `local` in its `projects[cwd]`,
    /// `project` in `.mcp.json`), a plugin (`plugin:<plugin>:<server>`), or a claude.ai connector (`claude.ai <name>`).
    public enum Source: String, Sendable, Codable, CaseIterable {
        case user, local, project, plugin
        case claudeAI = "claude.ai"
    }

    public enum Status: String, Sendable, Codable, CaseIterable {
        case pending, failed, needsAuth, connected
        /// Declared, and no delta said anything about it yet.
        case unknown
    }

    /// What a status was inferred from, when Claude Code did not report it.
    public enum Evidence: String, Sendable, Codable {
        /// Its tools were listed: only `authenticate` ones for `needsAuth`, real ones for `connected`.
        case toolsListed
        /// One of its tools was called.
        case toolCalled
        /// It was known and no delta lists it as pending, failed or needing authentication any more.
        case notReported
    }

    public struct Server: Sendable, Equatable, Identifiable {
        public var id: String { name }
        /// As Claude Code names it: `github`, `plugin:design:figma`, `claude.ai Linear`.
        public var name: String
        /// `nil` when nothing says where it comes from.
        public var source: Source?
        /// `stdio`, `http`, `sse`, … from the configuration; `nil` for a server it does not declare.
        public var transport: String?
        public var status: Status
        /// `true` when Scope deduced `status` (always for `connected`); `evidence` says from what.
        public var isInferred: Bool
        public var evidence: Evidence?
        /// A failed server's message and code (`CONNECTION_CLOSED`, `CONNECT_TIMEOUT`, `ENOTFOUND`, …).
        public var error: String?
        public var errorCode: String?
        /// Calls to its tools seen in this session.
        public var toolCalls: Int
        /// Tools Claude Code currently lists for it.
        public var tools: Int

        public init(name: String, source: Source? = nil, transport: String? = nil, status: Status, isInferred: Bool = false,
                    evidence: Evidence? = nil, error: String? = nil, errorCode: String? = nil, toolCalls: Int = 0,
                    tools: Int = 0) {
            self.name = name
            self.source = source
            self.transport = transport
            self.status = status
            self.isInferred = isInferred
            self.evidence = evidence
            self.error = error
            self.errorCode = errorCode
            self.toolCalls = toolCalls
            self.tools = tools
        }
    }

    /// A server the configuration declares (`ClaudeMCPConfig`).
    public struct Declaration: Sendable, Equatable {
        public var name: String
        public var source: Source
        public var transport: String?

        public init(name: String, source: Source, transport: String?) {
            self.name = name
            self.source = source
            self.transport = transport
        }
    }

    /// Tools a server lists while it waits for authentication, and nothing else.
    public static let authenticationTools: Set<String> = ["authenticate", "complete_authentication"]

    // Everything below is keyed by `MCPServerKey.key`.
    var names: [String: String] = [:]
    var declared: [String: Declaration] = [:]
    var hookSources: [String: Source] = [:]
    /// A delta naming servers arrived: from then on a known server in no list is taken as connected.
    var reported = false
    var pending: Set<String> = []
    var failed: [String: ClaudeMCPServerReport.Failure] = [:]
    var needsAuth: Set<String> = []
    var listedTools: [String: Set<String>] = [:]
    var calls: [String: Int] = [:]

    public init() {}

    /// Every server known, by name.
    public var servers: [Server] {
        let keys = Set(names.keys).union(declared.keys).union(calls.keys).union(listedTools.keys)
        return keys.map(server).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The failed ones, for a hint that does not need the whole list.
    public var failedServers: [Server] { servers.filter { $0.status == .failed } }
    public var isEmpty: Bool { servers.isEmpty }

    /// Replaces what the configuration declares: read again at each session start.
    public mutating func declare(_ declarations: [Declaration]) {
        declared = Dictionary(declarations.map { (MCPServerKey.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Counts a call to an MCP tool (`PostToolUse`, `PostToolUseFailure`: once per call, whatever its outcome).
    public mutating func apply(_ facts: ClaudeHookFacts) {
        guard facts.event == "PostToolUse" || facts.event == "PostToolUseFailure",
              let tool = facts.toolName, let server = MCPServerKey.server(ofTool: tool) else { return }
        calls[server, default: 0] += 1
        if let name = facts.body["mcp_server"]?["name"]?.nonEmptyString { names[server] = name }
        if let source = facts.body["mcp_server"]?["source"]?.nonEmptyString.flatMap(Source.init(rawValue:)) {
            hookSources[server] = source
        }
    }

    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for case .mcpServers(let report) in records { apply(report) }
    }

    mutating func apply(_ report: ClaudeMCPServerReport) {
        let named = report.pending + report.failed.map(\.name) + report.needsAuth
        for name in named { names[MCPServerKey.key(name)] = name }
        if report.carriesPending { pending = Set(report.pending.map(MCPServerKey.key)) }
        if report.carriesFailed {
            failed = Dictionary(report.failed.map { (MCPServerKey.key($0.name), $0) }, uniquingKeysWith: { _, last in last })
        }
        if report.carriesNeedsAuth { needsAuth = Set(report.needsAuth.map(MCPServerKey.key)) }
        if report.carriesPending || report.carriesFailed || report.carriesNeedsAuth { reported = true }
        for tool in report.addedTools {
            guard let server = MCPServerKey.server(ofTool: tool), let name = MCPServerKey.toolName(tool) else { continue }
            listedTools[server, default: []].insert(name)
        }
        for tool in report.removedTools {
            guard let server = MCPServerKey.server(ofTool: tool), let name = MCPServerKey.toolName(tool) else { continue }
            listedTools[server]?.remove(name)
            if listedTools[server]?.isEmpty == true { listedTools[server] = nil }
        }
    }

    private func server(_ key: String) -> Server {
        let declaration = declared[key]
        let name = names[key] ?? declaration?.name ?? key
        var server = Server(name: name, source: declaration?.source ?? hookSources[key] ?? Self.source(ofName: name),
                            transport: declaration?.transport, status: .unknown, toolCalls: calls[key] ?? 0,
                            tools: listedTools[key]?.count ?? 0)
        let tools = listedTools[key] ?? []
        if let failure = failed[key] {
            server.status = .failed
            server.error = failure.error
            server.errorCode = failure.code
        } else if needsAuth.contains(key) {
            server.status = .needsAuth
        } else if pending.contains(key) {
            server.status = .pending
        } else if !tools.isEmpty, tools.isSubset(of: Self.authenticationTools) {
            server.status = .needsAuth
            server.isInferred = true
            server.evidence = .toolsListed
        } else if !tools.isEmpty {
            server.status = .connected
            server.isInferred = true
            server.evidence = .toolsListed
        } else if server.toolCalls > 0 {
            server.status = .connected
            server.isInferred = true
            server.evidence = .toolCalled
        } else if reported {
            server.status = .connected
            server.isInferred = true
            server.evidence = .notReported
        }
        return server
    }

    /// The source a name gives away: plugins and claude.ai connectors are named after where they come from.
    static func source(ofName name: String) -> Source? {
        if name.hasPrefix("plugin:") { return .plugin }
        if name.hasPrefix("claude.ai ") { return .claudeAI }
        return nil
    }
}

/// How Claude Code turns a server name into the middle of its tool names (`mcp__<key>__<tool>`): every character
/// outside `[A-Za-z0-9_-]` becomes `_`. Observed: `claude.ai Claude Docs` → `claude_ai_Claude_Docs`,
/// `plugin:design:figma` → `plugin_design_figma`, `claude-in-chrome` unchanged.
public enum MCPServerKey {
    public static func key(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
            return allowed ? Character(scalar) : "_"
        })
    }

    /// `mcp__github__create_issue` → `github`; `nil` for a tool that is not an MCP one.
    public static func server(ofTool tool: String) -> String? {
        parts(tool)?.server
    }

    /// `mcp__github__create_issue` → `create_issue`.
    public static func toolName(_ tool: String) -> String? {
        parts(tool)?.tool
    }

    private static func parts(_ tool: String) -> (server: String, tool: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = tool.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let name = String(rest[separator.upperBound...])
        guard !server.isEmpty, !name.isEmpty else { return nil }
        return (server, name)
    }
}
