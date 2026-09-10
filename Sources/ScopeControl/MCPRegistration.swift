import Foundation
import ScopeCore

/// Registers `scope mcp` with the agents a user runs *outside* Scope — Claude Code, Codex, Cursor — so any of
/// their sessions can list, open threads and create tasks, not only a session Scope launched.
///
/// Each client keeps its servers in its own file, and Scope touches the one entry it owns. Claude Code's
/// `~/.claude.json` is rewritten by every running session, so it is only ever *read* here: the entry goes in and
/// out through `claude mcp add` / `remove`. Cursor's JSON and Codex's TOML are merged in place, everything else
/// in them left as it was.
///
/// The registered command is the helper inside the app bundle — a path that survives updates — pointed at this
/// app's home, so the installed app and a Debug build each reach their own socket under their own entry name.
public struct MCPRegistration: Sendable {
    public enum Client: String, CaseIterable, Sendable, Identifiable {
        case claudeCode, codex, cursor

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            }
        }
    }

    public enum State: Sendable, Equatable {
        /// The client is not on this machine.
        case unavailable
        case absent
        case installed
        /// An entry of that name points at another `scope` — a moved app, the other build.
        case stale(command: String)
    }

    /// The user's home, where every client keeps its configuration (a temporary folder in tests).
    public let userHome: URL
    /// Absolute path of the `scope` helper to register.
    public let tool: String
    /// The Scope home this app runs on, passed as `--home`.
    public let scopeHome: String
    /// `scope`, or `scope-debug` for a Debug build.
    public let name: String
    /// Environment for running `claude` (the login shell's, so a script-based install finds its interpreter).
    public let environment: [String: String]

    public init(userHome: URL, tool: String, scopeHome: String, debug: Bool, environment: [String: String] = [:]) {
        self.userHome = userHome
        self.tool = tool
        self.scopeHome = scopeHome
        self.name = debug ? "scope-debug" : "scope"
        self.environment = environment
    }

    /// Arguments of the registered command.
    public var arguments: [String] { ["mcp", "--home", scopeHome] }

    var claudeConfig: URL { userHome.appending(path: ".claude.json") }
    var cursorDirectory: URL { userHome.appending(path: ".cursor", directoryHint: .isDirectory) }
    var cursorConfig: URL { cursorDirectory.appending(path: "mcp.json") }
    var codexDirectory: URL { userHome.appending(path: ".codex", directoryHint: .isDirectory) }
    var codexConfig: URL { codexDirectory.appending(path: "config.toml") }

    // MARK: State

    /// Where `client` stands. `claudePath` is the `claude` executable, `nil` when it is not installed.
    public func state(of client: Client, claudePath: String?) -> State {
        switch client {
        case .claudeCode:
            guard claudePath != nil else { return .unavailable }
            return Self.jsonState(try? Data(contentsOf: claudeConfig), name: name, tool: tool)
        case .cursor:
            guard Self.isDirectory(cursorDirectory) else { return .unavailable }
            return Self.jsonState(try? Data(contentsOf: cursorConfig), name: name, tool: tool)
        case .codex:
            guard Self.isDirectory(codexDirectory) else { return .unavailable }
            return Self.tomlState((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "", name: name, tool: tool)
        }
    }

    // MARK: Install / remove

    /// Registers (or re-points) the entry for `client`.
    public func install(_ client: Client, claudePath: String?) async throws {
        switch client {
        case .claudeCode:
            guard let claudePath else { throw ControlError.failed("Claude Code is not installed") }
            // A stale entry of the same name would make `add` fail: replace it.
            _ = try? await runClaude(claudePath, ["mcp", "remove", "--scope", "user", name])
            try await runClaude(claudePath, ["mcp", "add", "--scope", "user", name, "--", tool] + arguments)
        case .cursor:
            let data = try Self.jsonInstalling(try? Data(contentsOf: cursorConfig), name: name, tool: tool, arguments: arguments)
            try Self.write(data, to: cursorConfig)
        case .codex:
            let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
            try Self.write(Data(Self.tomlInstalling(text, name: name, tool: tool, arguments: arguments).utf8), to: codexConfig)
        }
    }

    /// Removes the entry for `client`; nothing else in its configuration changes.
    public func remove(_ client: Client, claudePath: String?) async throws {
        switch client {
        case .claudeCode:
            guard let claudePath else { throw ControlError.failed("Claude Code is not installed") }
            try await runClaude(claudePath, ["mcp", "remove", "--scope", "user", name])
        case .cursor:
            guard let data = try Self.jsonRemoving(try? Data(contentsOf: cursorConfig), name: name) else { return }
            try Self.write(data, to: cursorConfig)
        case .codex:
            guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
            try Self.write(Data(Self.tomlRemoving(text, name: name).utf8), to: codexConfig)
        }
    }

    @discardableResult
    private func runClaude(_ path: String, _ arguments: [String]) async throws -> ProcessResult {
        var environment = self.environment
        environment["HOME"] = userHome.path
        let result = try await Subprocess.run(executable: path, arguments: arguments, environment: environment,
                                              timeout: .seconds(30))
        guard result.succeeded else {
            throw ControlError.failed("`claude \(arguments.prefix(2).joined(separator: " "))` failed",
                                      detail: result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
        return result
    }

    // MARK: JSON (Claude Code's user scope, Cursor)

    /// The entry named `name` under the top-level `mcpServers`.
    static func jsonState(_ data: Data?, name: String, tool: String) -> State {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[name] as? [String: Any] else { return .absent }
        let command = entry["command"] as? String ?? ""
        return command == tool ? .installed : .stale(command: command)
    }

    /// `data` with the entry added or re-pointed; every other key kept.
    static func jsonInstalling(_ data: Data?, name: String, tool: String, arguments: [String]) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ControlError.failed("the MCP configuration is not a JSON object; it was left alone")
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = ["command": tool, "args": arguments]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `data` without the entry, or `nil` when there is no file to change.
    static func jsonRemoving(_ data: Data?, name: String) throws -> Data? {
        guard let data, var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard servers.removeValue(forKey: name) != nil else { return nil }
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: TOML (Codex)

    static func tomlState(_ text: String, name: String, tool: String) -> State {
        let lines = text.components(separatedBy: "\n")
        guard let range = tomlTable(lines, name: name) else { return .absent }
        let command = lines[range].lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("command") && $0.contains("=") }
            .map { line in tomlUnquote(String(line[line.index(after: line.firstIndex(of: "=")!)...])) } ?? ""
        return command == tool ? .installed : .stale(command: command)
    }

    /// `text` with the table replaced by one pointing at `tool`; everything else kept.
    static func tomlInstalling(_ text: String, name: String, tool: String, arguments: [String]) -> String {
        var result = tomlRemoving(text, name: name)
        while result.hasSuffix("\n\n") { result.removeLast() }
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        result += "[mcp_servers.\(name)]\n"
        result += "command = \(tomlQuote(tool))\n"
        result += "args = [\(arguments.map(tomlQuote).joined(separator: ", "))]\n"
        return result
    }

    /// `text` without the table (and its sub-tables such as `[mcp_servers.scope.env]`).
    static func tomlRemoving(_ text: String, name: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let range = tomlTable(lines, name: name) {
            lines.removeSubrange(range)
        }
        return lines.joined(separator: "\n")
    }

    /// Lines of `[mcp_servers.<name>]` up to the next table that is not one of its own sub-tables.
    static func tomlTable(_ lines: [String], name: String) -> Range<Int>? {
        let header = "[mcp_servers.\(name)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let line = lines[end].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), !line.hasPrefix("[mcp_servers.\(name).") { break }
            end += 1
        }
        return start..<end
    }

    static func tomlQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tomlUnquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), let close = value.dropFirst().lastIndex(of: "\"") else { return value }
        value = String(value[value.index(after: value.startIndex)..<close])
        return value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Files

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ControlError.failed("could not write \(url.path)", detail: String(describing: error))
        }
    }
}
