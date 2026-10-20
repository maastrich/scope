import Foundation
import ScopeCore
import Testing
@testable import ScopeTasks

@Suite("TaskContextFiles")
struct TaskContextFilesTests {
    private func task(repos: [TaskRepo]) -> TaskRecord {
        TaskRecord(
            scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/s/acme", scopeSlug: "acme", scopeName: "Acme",
            name: "Auth", slug: "auth", branch: "scope/auth", root: "/h/sandboxes/acme/auth", repos: repos,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private let api = TaskRepo(repoRelativePath: "api", sandboxPath: "/h/sandboxes/acme/auth/api", branch: "scope/auth")
    private let web = TaskRepo(repoRelativePath: "web", sandboxPath: "/h/sandboxes/acme/auth/web", branch: "scope/auth")

    @Test("the names looked for are every declared name, the pivot, and each one's companion")
    func names() {
        #expect(TaskContextFiles.names(declared: ["CLAUDE.md", "AGENTS.md", "CLAUDE.md"]) == ["AGENTS.md", "CLAUDE.md", "CLAUDE.local.md"])
        #expect(TaskContextFiles.names(declared: []) == ["AGENTS.md"])
    }

    @Test("a one-repository task offers Scope's files first, then the repository's own, from the sandbox")
    func oneRepository() {
        let files: [String: TaskContextFiles.File] = [
            "/h/sandboxes/acme/auth/api/AGENTS.md": .init(size: 1_800, isGenerated: true),
            "/h/sandboxes/acme/auth/api/CLAUDE.md": .init(size: 6_100, isGenerated: false),
            "/h/sandboxes/acme/auth/api/CLAUDE.local.md": .init(size: 1_800, isGenerated: true),
        ]
        let offered = TaskContextFiles.offered(task: task(repos: [api]), declared: ["CLAUDE.md"]) { files[$0.path] }
        #expect(offered.map(\.name) == ["AGENTS.md", "CLAUDE.local.md", "CLAUDE.md"])
        #expect(offered.map(\.origin) == [.writtenByScope, .writtenByScope, .repository])
        #expect(offered.map(\.size) == [1_800, 1_800, 6_100])
        #expect(offered.allSatisfy { $0.sandbox == nil })
    }

    @Test("a task of several repositories offers the root's files, then each sandbox's, named by sandbox")
    func severalRepositories() {
        let files: [String: TaskContextFiles.File] = [
            "/h/sandboxes/acme/auth/AGENTS.md": .init(size: 2_000, isGenerated: true),
            "/h/sandboxes/acme/auth/api/CLAUDE.md": .init(size: 900, isGenerated: false),
            "/h/sandboxes/acme/auth/web/AGENTS.md": .init(size: 300, isGenerated: false),
        ]
        let offered = TaskContextFiles.offered(task: task(repos: [api, web]), declared: ["CLAUDE.md", "AGENTS.md"]) { files[$0.path] }
        #expect(offered.map(\.name) == ["AGENTS.md", "CLAUDE.md", "AGENTS.md"])
        #expect(offered.map(\.sandbox) == [nil, "api", "web"])
        #expect(offered.map(\.origin) == [.writtenByScope, .repository, .repository])
    }

    @Test("sizes read in bytes, kilobytes with a decimal under ten, megabytes above")
    func sizes() {
        #expect(TaskContextFiles.sizeText(412) == "412 B")
        #expect(TaskContextFiles.sizeText(1_800) == "1.8 kB")
        #expect(TaskContextFiles.sizeText(61_000) == "61 kB")
        #expect(TaskContextFiles.sizeText(1_270_000) == "1.3 MB")
    }

    @Test("skills are the sandboxes' .claude/skills folders that hold a SKILL.md, sorted, once each")
    func skills() {
        let tree: [String: [String]] = [
            "/h/sandboxes/acme/auth/api/.claude/skills": ["scope", "create-pr", ".DS_Store", "notes"],
            "/h/sandboxes/acme/auth/web/.claude/skills": ["scope", "artifact-design"],
        ]
        let skills = TaskContextFiles.skills(task: task(repos: [api, web])) { tree[$0.path] } isSkill: { $0.lastPathComponent != "notes" }
        #expect(skills == ["artifact-design", "create-pr", "scope"])
        #expect(TaskContextFiles.skills(task: task(repos: [api]), children: { _ in nil }, isSkill: { _ in true }).isEmpty)
    }
}
