import Foundation

/// The MCP servers Claude Code's configuration declares for a folder, read without ever writing: `~/.claude.json`
/// (`mcpServers`, the user scope, and `projects[<cwd>].mcpServers`, the local one) and the folder's `.mcp.json`
/// (the project scope, loaded only once approved).
///
/// Only a server's name and transport are kept. A declaration also holds commands, arguments, URLs, headers and
/// environment — tokens among them — and none of it leaves this function.
public enum ClaudeMCPConfig {
    /// `~/.claude.json`.
    public static func defaultClaudeJSON(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude.json", directoryHint: .notDirectory)
    }

    /// The servers declared for a session running in `cwd`; a file missing or unreadable declares none.
    public static func read(claudeJSON: URL, cwd: String) -> [ClaudeMCPServers.Declaration] {
        let global = object(at: claudeJSON) ?? [:]
        let project = (global["projects"] as? [String: Any])?[cwd] as? [String: Any] ?? [:]
        let disabled = Set(strings(project["disabledMcpServers"]))
        var found: [ClaudeMCPServers.Declaration] = []
        func add(_ servers: Any?, source: ClaudeMCPServers.Source, keep: (String) -> Bool = { _ in true }) {
            guard let servers = servers as? [String: Any] else { return }
            for (name, value) in servers where !name.isEmpty && !disabled.contains(name) && keep(name) {
                found.append(.init(name: name, source: source, transport: transport(value)))
            }
        }
        add(global["mcpServers"], source: .user)
        add(project["mcpServers"], source: .local)
        // A `.mcp.json` server runs once the user approved it, one by one or all at once, and not when rejected.
        let enabled = Set(strings(project["enabledMcpjsonServers"]))
        let rejected = Set(strings(project["disabledMcpjsonServers"]))
        let all = project["enableAllProjectMcpServers"] as? Bool == true
        let mcpJSON = URL(fileURLWithPath: cwd).appending(path: ".mcp.json", directoryHint: .notDirectory)
        add(object(at: mcpJSON)?["mcpServers"], source: .project) { name in
            !rejected.contains(name) && (all || enabled.contains(name))
        }
        // A name declared in several scopes is one server; the narrowest scope wins, as in Claude Code.
        var byName: [String: ClaudeMCPServers.Declaration] = [:]
        let rank: [ClaudeMCPServers.Source: Int] = [.local: 0, .project: 1, .user: 2]
        for declaration in found {
            if let known = byName[declaration.name], rank[known.source, default: 9] <= rank[declaration.source, default: 9] { continue }
            byName[declaration.name] = declaration
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// `type` when given; a declaration with a `command` and no type is a local process.
    static func transport(_ value: Any) -> String? {
        guard let server = value as? [String: Any] else { return nil }
        if let type = server["type"] as? String, !type.isEmpty { return type }
        return server["command"] != nil ? "stdio" : nil
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
