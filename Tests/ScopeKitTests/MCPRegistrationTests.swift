import Foundation
import Testing
@testable import ScopeControl

/// Registering `scope mcp` with the agents a user runs outside Scope, touching the one entry Scope owns.
@Suite struct MCPRegistrationTests {
    static let tool = "/Applications/Scope.app/Contents/Helpers/scope"
    static let args = ["mcp", "--home", "/Users/me/.scope"]

    static func temporaryHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-mcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func servers(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["mcpServers"] as? [String: Any])
    }

    // MARK: JSON

    @Test func aJSONInstallKeepsTheOtherServers() throws {
        let existing = Data(#"{"mcpServers":{"Linear":{"url":"https://mcp.linear.app/sse"}},"other":true}"#.utf8)
        let data = try MCPRegistration.jsonInstalling(existing, name: "scope", tool: Self.tool, arguments: Self.args)
        let servers = try Self.servers(data)
        #expect(servers["Linear"] != nil)
        #expect((servers["scope"] as? [String: Any])?["command"] as? String == Self.tool)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["other"] as? Bool == true)
        #expect(MCPRegistration.jsonState(data, name: "scope", tool: Self.tool) == .installed)
    }

    @Test func aJSONInstallStartsAMissingFile() throws {
        let data = try MCPRegistration.jsonInstalling(nil, name: "scope", tool: Self.tool, arguments: Self.args)
        #expect(MCPRegistration.jsonState(data, name: "scope", tool: Self.tool) == .installed)
    }

    @Test func anEntryPointingElsewhereIsStaleAndGetsRepointed() throws {
        let old = Data(#"{"mcpServers":{"scope":{"command":"/old/Scope.app/Contents/Helpers/scope","args":["mcp"]}}}"#.utf8)
        #expect(MCPRegistration.jsonState(old, name: "scope", tool: Self.tool) == .stale(command: "/old/Scope.app/Contents/Helpers/scope"))
        let fixed = try MCPRegistration.jsonInstalling(old, name: "scope", tool: Self.tool, arguments: Self.args)
        #expect(MCPRegistration.jsonState(fixed, name: "scope", tool: Self.tool) == .installed)
    }

    @Test func aJSONRemoveTakesOnlyItsEntry() throws {
        let existing = Data(#"{"mcpServers":{"Linear":{"url":"u"},"scope":{"command":"x"}}}"#.utf8)
        let data = try #require(try MCPRegistration.jsonRemoving(existing, name: "scope"))
        let servers = try Self.servers(data)
        #expect(servers["scope"] == nil)
        #expect(servers["Linear"] != nil)
        #expect(try MCPRegistration.jsonRemoving(data, name: "scope") == nil, "nothing left to remove: no write")
    }

    @Test func aFileThatIsNotAnObjectIsLeftAlone() {
        #expect(throws: ControlError.self) {
            try MCPRegistration.jsonInstalling(Data("[1,2]".utf8), name: "scope", tool: Self.tool, arguments: Self.args)
        }
    }

    // MARK: TOML

    @Test func aTOMLInstallAppendsATableAndKeepsTheRest() {
        let existing = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"
        let text = MCPRegistration.tomlInstalling(existing, name: "scope", tool: Self.tool, arguments: Self.args)
        #expect(text.hasPrefix("model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"))
        #expect(text.contains("[mcp_servers.scope]\ncommand = \"\(Self.tool)\"\nargs = [\"mcp\", \"--home\", \"/Users/me/.scope\"]\n"))
        #expect(MCPRegistration.tomlState(text, name: "scope", tool: Self.tool) == .installed)
        #expect(MCPRegistration.tomlState(text, name: "scope", tool: "/elsewhere") == .stale(command: Self.tool))
    }

    @Test func aTOMLInstallReplacesItsOwnTableInsteadOfDuplicatingIt() {
        let old = "[mcp_servers.scope]\ncommand = \"/old\"\nargs = [\"mcp\"]\n\n[mcp_servers.scope.env]\nX = \"1\"\n\n[profile]\nname = \"me\"\n"
        let text = MCPRegistration.tomlInstalling(old, name: "scope", tool: Self.tool, arguments: Self.args)
        #expect(text.components(separatedBy: "[mcp_servers.scope]").count == 2)
        #expect(!text.contains("/old"))
        #expect(!text.contains("[mcp_servers.scope.env]"))
        #expect(text.contains("[profile]\nname = \"me\""))
    }

    @Test func aTOMLRemoveTakesOnlyItsTable() {
        let text = "[a]\nx = 1\n\n[mcp_servers.scope]\ncommand = \"c\"\n\n[b]\ny = 2\n"
        let removed = MCPRegistration.tomlRemoving(text, name: "scope")
        #expect(!removed.contains("mcp_servers.scope"))
        #expect(removed.contains("[a]\nx = 1") && removed.contains("[b]\ny = 2"))
        #expect(MCPRegistration.tomlState(removed, name: "scope", tool: "c") == .absent)
    }

    // MARK: Clients on disk

    @Test func clientsThatAreNotHereAreUnavailable() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let registration = MCPRegistration(userHome: home, tool: Self.tool, scopeHome: "/h", debug: false)
        #expect(registration.state(of: .cursor, claudePath: nil) == .unavailable)
        #expect(registration.state(of: .codex, claudePath: nil) == .unavailable)
        #expect(registration.state(of: .claudeCode, claudePath: nil) == .unavailable)
    }

    @Test func cursorAndCodexRoundTripOnDisk() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try Data("model = \"o3\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))
        let registration = MCPRegistration(userHome: home, tool: Self.tool, scopeHome: "/h", debug: false)

        for client in [MCPRegistration.Client.cursor, .codex] {
            #expect(registration.state(of: client, claudePath: nil) == .absent)
            try await registration.install(client, claudePath: nil)
            #expect(registration.state(of: client, claudePath: nil) == .installed)
            try await registration.remove(client, claudePath: nil)
            #expect(registration.state(of: client, claudePath: nil) == .absent)
        }
        let codex = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(codex.hasPrefix("model = \"o3\""))
    }

    /// Claude Code is driven through its own CLI; a stand-in records what it was asked.
    @Test func claudeCodeGoesThroughItsOwnCommandLine() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = home.appending(path: "claude")
        try Data("#!/bin/sh\necho \"$@\" >> \"$HOME/calls.txt\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let registration = MCPRegistration(userHome: home, tool: Self.tool, scopeHome: "/h", debug: true)

        try await registration.install(.claudeCode, claudePath: fake.path)
        try await registration.remove(.claudeCode, claudePath: fake.path)
        let calls = try String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == [
            "mcp remove --scope user scope-debug",
            "mcp add --scope user scope-debug -- \(Self.tool) mcp --home /h",
            "mcp remove --scope user scope-debug",
        ])
    }

    @Test func aDebugBuildRegistersUnderItsOwnName() {
        #expect(MCPRegistration(userHome: URL(fileURLWithPath: "/"), tool: "t", scopeHome: "h", debug: true).name == "scope-debug")
        #expect(MCPRegistration(userHome: URL(fileURLWithPath: "/"), tool: "t", scopeHome: "h", debug: false).name == "scope")
    }
}
