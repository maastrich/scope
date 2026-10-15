import Foundation
import Testing
@testable import ScopeControl

/// Installing the Scope skill at user level for each agent, touching the one folder Scope owns.
@Suite struct SkillInstallerTests {
    static func temporaryHome(clients: [SkillInstaller.Client] = SkillInstaller.Client.allCases) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-skill-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let installer = SkillInstaller(userHome: url, debug: false)
        for client in clients {
            try FileManager.default.createDirectory(at: installer.clientHome(client), withIntermediateDirectories: true)
        }
        return url
    }

    @Test func installWritesTheSkillWhereEachClientReadsIt() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        for client in SkillInstaller.Client.allCases {
            #expect(installer.state(of: client) == .absent)
            try installer.install(client)
            #expect(installer.state(of: client) == .installed)
        }
        #expect(installer.skillFile(.claudeCode).path == home.appending(path: ".claude/skills/scope/SKILL.md").path)
        #expect(installer.skillFile(.codex).path == home.appending(path: ".codex/skills/scope/SKILL.md").path)
        #expect(installer.skillFile(.cursor).path == home.appending(path: ".cursor/skills/scope/SKILL.md").path)
        let text = try String(contentsOf: installer.skillFile(.claudeCode), encoding: .utf8)
        #expect(text.hasPrefix("---\nname: scope\n"), "the frontmatter names the skill")
        #expect(text.contains("scope task new") && text.contains("scope_task_new"), "the CLI and the MCP tools are both taught")
    }

    @Test func aClientWithoutAHomeIsUnavailable() throws {
        let home = try Self.temporaryHome(clients: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        #expect(installer.state(of: .codex) == .unavailable)
        #expect(installer.state(of: .claudeCode) == .absent)
    }

    @Test func anOlderCopyReadsAsOutdatedAndIsRewritten() throws {
        let home = try Self.temporaryHome(clients: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        try FileManager.default.createDirectory(at: installer.skillDirectory(.claudeCode), withIntermediateDirectories: true)
        try "---\nname: scope\n---\n<!-- scope-skill-version: 0 -->\nold text\n"
            .write(to: installer.skillFile(.claudeCode), atomically: true, encoding: .utf8)
        #expect(installer.state(of: .claudeCode) == .outdated)
        try installer.install(.claudeCode)
        #expect(installer.state(of: .claudeCode) == .installed)
        #expect(SkillInstaller.installedVersion(try String(contentsOf: installer.skillFile(.claudeCode), encoding: .utf8)) == SkillInstaller.version)
    }

    @Test func aForeignSkillOfTheSameNameIsNeverTouched() throws {
        let home = try Self.temporaryHome(clients: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        try FileManager.default.createDirectory(at: installer.skillDirectory(.claudeCode), withIntermediateDirectories: true)
        try "---\nname: scope\n---\nsomeone else's skill\n".write(to: installer.skillFile(.claudeCode), atomically: true, encoding: .utf8)
        #expect(installer.state(of: .claudeCode) == .foreign)
        #expect(throws: ControlError.self) { try installer.install(.claudeCode) }
        try installer.remove(.claudeCode)
        #expect(installer.state(of: .claudeCode) == .foreign, "remove leaves it alone too")
    }

    @Test func removeDeletesOnlyOurFolder() throws {
        let home = try Self.temporaryHome(clients: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        let neighbour = installer.clientHome(.claudeCode).appending(path: "skills/other/SKILL.md")
        try FileManager.default.createDirectory(at: neighbour.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "theirs".write(to: neighbour, atomically: true, encoding: .utf8)
        try installer.install(.claudeCode)
        try installer.remove(.claudeCode)
        #expect(installer.state(of: .claudeCode) == .absent)
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        try installer.remove(.claudeCode)   // idempotent
    }

    @Test func theDebugBuildKeepsItsOwnName() {
        let installer = SkillInstaller(userHome: URL(fileURLWithPath: "/tmp"), debug: true)
        #expect(installer.name == "scope-debug" && installer.legacyName == "scope-debug-tasks")
        #expect(installer.skillText.contains("`scope-debug` MCP tools"))
    }

    /// The skill teaches both façades: a session outside Scope has only the MCP tools, one inside reaches for the CLI.
    @Test func theSkillNamesEveryToolAndItsCommand() {
        let text = SkillInstaller(userHome: URL(fileURLWithPath: "/tmp"), debug: false).skillText
        for tool in MCPBridge.tools {
            #expect(text.contains("`\(tool.name)`"), "\(tool.name) is not taught")
        }
        for command in ["scope thread wait", "--reply", "scope task new", "scope thread send", "scope ping"] {
            #expect(text.contains(command), "\(command) is not taught")
        }
        #expect(text.contains("untrusted"))
        #expect(SkillInstaller.installedVersion(text) == SkillInstaller.version)
    }

    /// At launch, only our own older copies are rewritten: an agent the user never installed it for, and a folder
    /// that is not ours, stay as they are.
    @Test func launchRefreshesOnlyOurOutdatedCopies() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        for client in [SkillInstaller.Client.claudeCode, .cursor] {
            try FileManager.default.createDirectory(at: installer.skillDirectory(client), withIntermediateDirectories: true)
        }
        try "<!-- scope-skill-version: 1 -->\nold\n".write(to: installer.skillFile(.claudeCode), atomically: true, encoding: .utf8)
        try "someone else's skill\n".write(to: installer.skillFile(.cursor), atomically: true, encoding: .utf8)
        #expect(installer.refreshOutdated() == [.claudeCode])
        #expect(installer.state(of: .claudeCode) == .installed)
        #expect(installer.state(of: .codex) == .absent)
        #expect(installer.state(of: .cursor) == .foreign)
        #expect(installer.refreshOutdated().isEmpty, "nothing left to rewrite")
    }

    /// The skill was `scope-tasks` before it covered threads too: a copy under the old name moves to the new one,
    /// so the two never sit side by side triggering on the same requests.
    @Test func aCopyUnderTheOldNameMovesToTheNewOne() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        for client in [SkillInstaller.Client.claudeCode, .codex] {
            try FileManager.default.createDirectory(at: installer.legacyDirectory(client), withIntermediateDirectories: true)
        }
        try "---\nname: scope-tasks\n---\n<!-- scope-skill-version: 1 -->\nold\n"
            .write(to: installer.legacyDirectory(.claudeCode).appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try "someone else's scope-tasks\n"
            .write(to: installer.legacyDirectory(.codex).appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(installer.state(of: .claudeCode) == .outdated)
        #expect(installer.state(of: .codex) == .absent, "a folder we did not write is not ours to move")

        #expect(installer.refreshOutdated() == [.claudeCode])
        #expect(installer.state(of: .claudeCode) == .installed)
        #expect(!FileManager.default.fileExists(atPath: installer.legacyDirectory(.claudeCode).path))
        #expect(FileManager.default.fileExists(atPath: installer.legacyDirectory(.codex).path))
    }

    @Test func removeAlsoTakesACopyUnderTheOldName() throws {
        let home = try Self.temporaryHome(clients: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(userHome: home, debug: false)
        try FileManager.default.createDirectory(at: installer.legacyDirectory(.claudeCode), withIntermediateDirectories: true)
        try "<!-- scope-skill-version: 3 -->\n"
            .write(to: installer.legacyDirectory(.claudeCode).appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try installer.remove(.claudeCode)
        #expect(installer.state(of: .claudeCode) == .absent)
        #expect(!FileManager.default.fileExists(atPath: installer.legacyDirectory(.claudeCode).path))
    }
}
