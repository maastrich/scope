import Foundation
import Testing
@testable import ScopeControl

/// Installing the Scope tasks skill at user level for each agent, touching the one folder Scope owns.
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
        #expect(installer.skillFile(.claudeCode).path == home.appending(path: ".claude/skills/scope-tasks/SKILL.md").path)
        #expect(installer.skillFile(.codex).path == home.appending(path: ".codex/skills/scope-tasks/SKILL.md").path)
        #expect(installer.skillFile(.cursor).path == home.appending(path: ".cursor/skills/scope-tasks/SKILL.md").path)
        let text = try String(contentsOf: installer.skillFile(.claudeCode), encoding: .utf8)
        #expect(text.hasPrefix("---\nname: scope-tasks\n"), "the frontmatter names the skill")
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
        try "---\nname: scope-tasks\n---\n<!-- scope-skill-version: 0 -->\nold text\n"
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
        try "---\nname: scope-tasks\n---\nsomeone else's skill\n".write(to: installer.skillFile(.claudeCode), atomically: true, encoding: .utf8)
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
        #expect(installer.name == "scope-debug-tasks")
        #expect(installer.skillText.contains("`scope-debug` MCP tools"))
    }
}
