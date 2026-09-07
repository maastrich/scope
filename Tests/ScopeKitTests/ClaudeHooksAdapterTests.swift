import Foundation
import ScopeAdapters
import ScopeCore
import Testing
@testable import ScopeDrivers

@Suite("ClaudeHooksAdapter")
struct ClaudeHooksAdapterTests {
    static func temporaryHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-adapter-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let hookPath = "/Applications/Scope.app/Contents/Helpers/scope-hook"

    func hooks(_ document: [String: Any]) throws -> [String: [[String: Any]]] {
        try #require(document["hooks"] as? [String: [[String: Any]]])
    }

    func commands(_ document: [String: Any], _ event: String) throws -> [String] {
        let groups = try #require(try hooks(document)[event])
        return try groups.flatMap { group in
            try #require(group["hooks"] as? [[String: Any]]).map { try #require($0["command"] as? String) }
        }
    }

    @Test("the settings document declares every hook of the mapping under the documented shape")
    func settingsShape() throws {
        let document = ClaudeHooksAdapter.settings(scopeHookPath: Self.hookPath)
        let hooks = try hooks(document)
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"])
        for (event, groups) in hooks {
            #expect(groups.count == 1, Comment(rawValue: event))
            let entries = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(entries.count == 1, Comment(rawValue: event))
            #expect(entries[0]["type"] as? String == "command", Comment(rawValue: event))
            #expect(entries[0]["timeout"] as? Int == ClaudeHooksAdapter.hookTimeout, Comment(rawValue: event))
            let command = try #require(entries[0]["command"] as? String)
            #expect(command.hasPrefix(Self.hookPath + " "), Comment(rawValue: event))
            #expect(command.hasSuffix(" --stdin"), Comment(rawValue: event))
        }
    }

    @Test("each Claude Code hook maps onto the intended scope-hook event")
    func mapping() throws {
        let document = ClaudeHooksAdapter.settings(scopeHookPath: Self.hookPath)
        #expect(try commands(document, "SessionStart") == ["\(Self.hookPath) session.started --stdin"])
        #expect(try commands(document, "UserPromptSubmit") == ["\(Self.hookPath) turn.started --stdin"])
        #expect(try commands(document, "PostToolUse") == ["\(Self.hookPath) turn.started --stdin"])
        #expect(try commands(document, "PermissionRequest") == ["\(Self.hookPath) permission.requested --stdin"])
        #expect(try commands(document, "Notification") == ["\(Self.hookPath) notification --stdin"])
        #expect(try commands(document, "Stop") == ["\(Self.hookPath) turn.ended --stdin"])
        #expect(try commands(document, "SessionEnd") == ["\(Self.hookPath) thread.ended --stdin"])
        // Only Notification carries a matcher, and it selects the "someone must act" types.
        let hooks = try hooks(document)
        for (event, groups) in hooks where event != "Notification" {
            #expect(groups[0]["matcher"] == nil, Comment(rawValue: event))
        }
        let matcher = try #require(hooks["Notification"]?[0]["matcher"] as? String)
        #expect(matcher.split(separator: "|").contains("permission_prompt"))
        #expect(matcher.split(separator: "|").contains("idle_prompt"))
        #expect(!matcher.contains("auth_success"))
    }

    @Test("a hook path with spaces or quotes is shell-quoted")
    func quoting() {
        let spaced = "/Users/Jane Doe/Applications/Scope.app/Contents/Helpers/scope-hook"
        #expect(ClaudeHooksAdapter.command(scopeHookPath: spaced, arguments: ["turn.ended", "--stdin"])
                == "'\(spaced)' turn.ended --stdin")
        #expect(ClaudeHooksAdapter.shellQuote("/plain/path-1.0/scope-hook") == "/plain/path-1.0/scope-hook")
        #expect(ClaudeHooksAdapter.shellQuote("it's") == "'it'\\''s'")
        #expect(ClaudeHooksAdapter.shellQuote("$HOME/x") == "'$HOME/x'")
        #expect(ClaudeHooksAdapter.shellQuote("") == "''")
    }

    @Test("the serialized file is valid JSON that decodes back to the same hooks")
    func serialization() throws {
        let data = try ClaudeHooksAdapter.settingsData(scopeHookPath: Self.hookPath)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try commands(decoded, "Stop") == ["\(Self.hookPath) turn.ended --stdin"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\\/"), "slashes are not escaped, the file stays readable")
    }

    @Test("install writes <home>/threads/<id>.claude-settings.json and returns --settings <path>")
    func install() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = ThreadID.generate()
        let arguments = try ClaudeHooksAdapter.install(home: home, threadID: id, scopeHookPath: Self.hookPath)
        let expected = home.appending(path: "threads/\(id.rawValue).claude-settings.json").path
        #expect(arguments == ["--settings", expected])
        let data = try Data(contentsOf: URL(fileURLWithPath: expected))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try commands(decoded, "SessionEnd") == ["\(Self.hookPath) thread.ended --stdin"])

        // Rewriting with a new hook path keeps the file current.
        _ = try ClaudeHooksAdapter.install(home: home, threadID: id, scopeHookPath: "/opt/scope-hook")
        let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: expected))) as? [String: Any])
        #expect(try commands(rewritten, "Stop") == ["/opt/scope-hook turn.ended --stdin"])

        ClaudeHooksAdapter.uninstall(home: home, threadID: id)
        #expect(!FileManager.default.fileExists(atPath: expected))
        ClaudeHooksAdapter.uninstall(home: home, threadID: id)   // idempotent
    }

    @Test("AdapterInstaller only acts for claude-hooks")
    func installerDispatch() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = ThreadID.generate()
        let claude = DriverProfile(id: "claude-code", name: "Claude Code", command: "claude", adapter: .init(kind: "claude-hooks"))
        let shell = DriverProfile(id: "shell", name: "Shell", command: "$SHELL")
        let codex = DriverProfile(id: "codex", name: "Codex", command: "codex", adapter: .init(kind: "codex-notify"))
        #expect(try AdapterInstaller.prepare(profile: claude, threadID: id, home: home, scopeHookPath: Self.hookPath).first == "--settings")
        #expect(try AdapterInstaller.prepare(profile: shell, threadID: id, home: home, scopeHookPath: Self.hookPath).isEmpty)
        #expect(try AdapterInstaller.prepare(profile: codex, threadID: id, home: home, scopeHookPath: Self.hookPath).isEmpty)
    }

    @Test("the launcher appends --settings on a fresh launch and on a resume")
    func launchPlanCarriesSettings() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = ThreadID.generate()
        let profile = DriverProfile(id: "claude-code", name: "Claude Code", command: "/bin/echo",
                                    resume: ["/bin/echo", "--resume", "{resume_id}"], adapter: .init(kind: "claude-hooks"))
        let adapterArguments = try AdapterInstaller.prepare(profile: profile, threadID: id, home: home, scopeHookPath: Self.hookPath)
        let shell = ResolvedShellEnvironment(shell: "/bin/zsh", variables: ["PATH": "/usr/bin:/bin"], source: .login)
        let scope = TerminalEnvironment.ScopeVariables(thread: id.rawValue, scope: "acme", scopeRoot: home.path,
                                                       sock: home.appending(path: "scope.sock").path, home: home.path)
        func values(resumeID: String?) -> PlaceholderValues {
            PlaceholderValues(threadID: id.rawValue, resumeID: resumeID, cwd: home.path, scope: home.path, home: home.path, scopeHook: Self.hookPath)
        }
        let settingsPath = ClaudeHooksAdapter.settingsURL(home: home, threadID: id).path

        let launch = try LaunchPlanner.plan(profile: profile, mode: .launch, values: values(resumeID: nil), shellEnvironment: shell,
                                            scopeVariables: scope, appVersion: "0.1.0", adapterArguments: adapterArguments)
        #expect(launch.arguments == ["--settings", settingsPath])

        let resume = try LaunchPlanner.plan(profile: profile, mode: .resume, values: values(resumeID: "sess-1"), shellEnvironment: shell,
                                            scopeVariables: scope, appVersion: "0.1.0", adapterArguments: adapterArguments)
        #expect(resume.arguments == ["--resume", "sess-1", "--settings", settingsPath])
        #expect(resume.displayCommand.hasPrefix("/bin/echo --resume sess-1 --settings"))

        #expect(throws: LaunchError.resumeUnavailable) {
            try LaunchPlanner.plan(profile: profile, mode: .resume, values: values(resumeID: nil), shellEnvironment: shell,
                                   scopeVariables: scope, appVersion: "0.1.0", adapterArguments: adapterArguments)
        }
    }

    @Test("the bundled claude-code and codex profiles are ready for the adapters")
    func bundledProfiles() throws {
        let profiles = try DriverRegistry.bundledProfiles()
        let claude = try #require(profiles.first { $0.id == "claude-code" })
        #expect(claude.adapter?.kind == ClaudeHooksAdapter.kind)
        #expect(claude.resume == ["claude", "--resume", "{resume_id}"])

        let codex = try #require(profiles.first { $0.id == "codex" })
        try codex.validate()
        let values = PlaceholderValues(threadID: "3f9a2c17be04", resumeID: "t-1", cwd: "/tmp", scope: "/tmp", home: "/tmp", scopeHook: "/opt/scope-hook")
        #expect(try values.expand(codex.args) == ["-c", #"notify=["/opt/scope-hook","turn.ended","--stdin"]"#])
        #expect(try values.expand(codex.resume ?? []).contains("resume"))
        let missing = PlaceholderValues(threadID: "3f9a2c17be04", cwd: "/tmp", scope: "/tmp", home: "/tmp")
        #expect(throws: LaunchError.placeholderUnavailable(.scopeHook)) { try missing.expand(codex.args) }
    }

    @Test("ScopeHookLocator prefers the embedded helper, then PATH, then the bare name")
    func locator() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = home.appending(path: "Scope.app", directoryHint: .isDirectory)
        let embedded = bundle.appending(path: ScopeHookLocator.bundleSubpath)
        let onPath = home.appending(path: "bin/scope-hook")
        for url in [embedded, onPath] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let binDirectory = onPath.deletingLastPathComponent().path
        #expect(ScopeHookLocator.locate(bundleURL: bundle, searchPATH: binDirectory) == embedded.path)
        #expect(ScopeHookLocator.locate(bundleURL: nil, searchPATH: binDirectory) == onPath.path)
        #expect(ScopeHookLocator.locate(bundleURL: home, searchPATH: "/nonexistent") == "scope-hook")
    }
}
