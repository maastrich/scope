import Foundation
import Testing
@testable import ScopeCore
@testable import ScopeDrivers
@testable import ScopeTasks

@Suite("ClaudeMemory")
struct ClaudeMemoryTests {
    static let locator = ClaudeMemory.Locator(configDirectory: URL(fileURLWithPath: "/home/.claude", isDirectory: true))

    static func task(repos: [TaskRepo], root: String = "/sandboxes/acme/fix") -> TaskRecord {
        TaskRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/work/acme", scopeSlug: "acme", scopeName: "@acme",
                   name: "Fix", slug: "fix", branch: "fix", root: root, repos: repos)
    }

    static let multi = task(repos: [
        TaskRepo(repoRelativePath: "front", sandboxPath: "/sandboxes/acme/fix/front", branch: "fix",
                 worktrees: [TaskWorktree(branch: "other", sandboxPath: "/sandboxes/acme/fix/front@other")]),
        TaskRepo(repoRelativePath: "api", sandboxPath: "/sandboxes/acme/fix/api", branch: "fix"),
    ])

    @Test func folderNamesMatchClaudeCode() {
        #expect(ClaudeMemory.projectFolderName("/Users/maastrich/contributions/@maastrich/scope")
                == "-Users-maastrich-contributions--maastrich-scope")
        #expect(ClaudeMemory.projectFolderName("/Users/maastrich/.scope/sandboxes/x") == "-Users-maastrich--scope-sandboxes-x")
        // One `-` per UTF-16 unit: two for an emoji.
        #expect(ClaudeMemory.projectFolderName("/tmp/café/🙂") == "-tmp-caf----")
        // Reference computed with Claude Code's own function (node).
        let long = "/Users/someone/" + String(repeating: "very-long-folder-name/", count: 10) + "repo"
        #expect(ClaudeMemory.projectFolderName(long) == "-Users-someone" + String(repeating: "-very-long-folder-name", count: 8)
                + "-very-long-mjvq3")
    }

    @Test func aSandboxThreadUsesItsRepositoryAndTheRootUsesTheScope() {
        let front = ClaudeMemory.placement(cwd: "/sandboxes/acme/fix/front/src", task: Self.multi, locator: Self.locator)
        #expect(front.owner == .repository("front"))
        #expect(front.directory.path == "/home/.claude/projects/-work-acme-front/memory")
        let secondary = ClaudeMemory.placement(cwd: "/sandboxes/acme/fix/front@other", task: Self.multi, locator: Self.locator)
        #expect(secondary.owner == .repository("front"))
        let root = ClaudeMemory.placement(cwd: "/sandboxes/acme/fix", task: Self.multi, locator: Self.locator)
        #expect(root.owner == .scope)
        #expect(root.directory.path == "/home/.claude/projects/-work-acme/memory")
        let companions = ClaudeMemory.companions(of: root, task: Self.multi, locator: Self.locator)
        #expect(companions.map(\.owner) == [.repository("front"), .repository("api")])
        #expect(ClaudeMemory.companions(of: front, task: Self.multi, locator: Self.locator).map(\.owner) == [.scope, .repository("api")])
    }

    @Test func aRepoScopeHasOneMemory() {
        let record = Self.task(repos: [TaskRepo(repoRelativePath: ".", sandboxPath: "/sandboxes/acme/fix", branch: "fix")])
        let own = ClaudeMemory.placement(cwd: "/sandboxes/acme/fix", task: record, locator: Self.locator)
        #expect(own.owner == .repository("."))
        #expect(own.directory.path == "/home/.claude/projects/-work-acme/memory")
        #expect(ClaudeMemory.companions(of: own, task: record, locator: Self.locator).isEmpty)
    }

    @Test func theUsersOwnChoiceWins() {
        let none: (URL) -> Data? = { _ in nil }
        let plain = ClaudeMemory.Locator.resolve(environment: [:], userHome: "/home", userSettings: none)
        #expect(plain?.configDirectory.path == "/home/.claude")
        let custom = ClaudeMemory.Locator.resolve(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], userHome: "/home", userSettings: none)
        #expect(custom?.configDirectory.path == "/cfg")
        #expect(ClaudeMemory.Locator.resolve(environment: ["CLAUDE_CODE_PROJECT_DIR_NAME": "x"], userHome: "/home", userSettings: none) == nil)
        #expect(ClaudeMemory.Locator.resolve(environment: ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"], userHome: "/home", userSettings: none) == nil)
        let ownFolder = ClaudeMemory.Locator.resolve(environment: [:], userHome: "/home") { url in
            url.path == "/home/.claude/settings.json" ? Data(#"{"autoMemoryDirectory":"~/mem"}"#.utf8) : nil
        }
        #expect(ownFolder == nil)
        let off = ClaudeMemory.Locator.resolve(environment: [:], userHome: "/home") { _ in Data(#"{"autoMemoryEnabled":false}"#.utf8) }
        #expect(off == nil)
    }

    @Test func theSettingsFileCarriesTheMemory() throws {
        let memory = ThreadMemorySettings(directory: "/m/repo", readable: ["/m/scope"])
        let document = ClaudeHooksAdapter.settings(scopeHookPath: "/bin/scope-hook", memory: memory)
        #expect(document["autoMemoryDirectory"] as? String == "/m/repo")
        #expect((document["permissions"] as? [String: Any])?["additionalDirectories"] as? [String] == ["/m/scope"])
        #expect(document["hooks"] != nil)
        let without = ClaudeHooksAdapter.settings(scopeHookPath: "/bin/scope-hook")
        #expect(without["autoMemoryDirectory"] == nil && without["permissions"] == nil)
    }

    @Test func theContextFileQuotesTheScopeIndex() {
        let record = Self.task(repos: [TaskRepo(repoRelativePath: "front", sandboxPath: "/sandboxes/acme/fix/front", branch: "fix")])
        let lines = ClaudeMemory.contextSection(task: record, locator: Self.locator) { url in
            url.path == "/home/.claude/projects/-work-acme/memory/MEMORY.md" ? "- [Branches](branches.md) — prefix with feat/\n" : nil
        }
        let text = lines.joined(separator: "\n")
        #expect(text.contains("memory of **front** (`/home/.claude/projects/-work-acme-front/memory`)"))
        #expect(text.contains("- [Branches](branches.md) — prefix with feat/"))
        let markdown = TaskProjection.agentsMarkdown(task: record, otherRepos: [], scopeName: "@acme", memorySection: lines)
        #expect(markdown.contains("## Memory"))
        #expect(markdown.range(of: "## Memory")!.lowerBound < markdown.range(of: "## Rules")!.lowerBound)
    }
}

@Suite("ClaudeMemoryRecovery")
struct ClaudeMemoryRecoveryTests {
    /// A Claude config folder, a scope and an outside clone, all on disk under a fresh temporary folder.
    struct Fixture {
        let base: String
        var config: String { base + "/claude" }
        var projects: String { config + "/projects" }
        var scopeRoot: String { base + "/work/acme" }
        var sandboxes: String { base + "/home/sandboxes" }
        var clone: String { base + "/elsewhere/front" }
        var locator: ClaudeMemory.Locator { ClaudeMemory.Locator(configDirectory: URL(fileURLWithPath: config)) }

        init() throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "claude-memory-\(UUID().uuidString)")
            base = ClaudeMemory.canonicalPath(url.path)
            for folder in [scopeRoot + "/front", scopeRoot + "/api", clone, sandboxes] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
        }

        func memory(of path: String) -> String {
            locator.memoryDirectory(forProject: path).path(percentEncoded: false)
        }

        func write(_ files: [String: String], into directory: String) throws {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, text) in files { try text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8) }
        }

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        var disk: ClaudeMemoryRecovery.Disk {
            let clone = clone
            return ClaudeMemoryRecovery.Disk(children: ClaudeMemoryRecovery.Disk.live.children, read: ClaudeMemoryRecovery.Disk.live.read,
                                             remote: { $0 == clone ? "git@github.com:Acme/front.git" : nil })
        }

        var scope: ClaudeMemoryRecovery.Scope {
            ClaudeMemoryRecovery.Scope(slug: "acme", name: "@acme", root: scopeRoot, repos: [
                .init(relativePath: "front", remote: "https://github.com/acme/front"),
                .init(relativePath: "api", remote: nil),
            ])
        }

        func task(slug: String) -> TaskRecord {
            let root = sandboxes + "/acme/" + slug
            return TaskRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: scopeRoot, scopeSlug: "acme", scopeName: "@acme",
                              name: slug, slug: slug, branch: slug, root: root, repos: [
                                TaskRepo(repoRelativePath: "front", sandboxPath: root + "/front", branch: slug, state: .archived),
                                TaskRepo(repoRelativePath: "api", sandboxPath: root + "/api", branch: slug, state: .archived),
                              ], archivedAt: .now)
        }

        func note(_ name: String, _ body: String) -> String { "---\nname: \(name)\ndescription: about \(name)\n---\n\(body)\n" }
    }

    @Test func aTaskRootGoesToTheScopeAndACloneToItsRepository() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(atPath: f.base) }
        // The scope's own memory already knows `branches`.
        try f.write(["branches.md": f.note("branches", "feat/ prefix"), "MEMORY.md": "- [Branches](branches.md) — feat/\n"],
                    into: f.memory(of: f.scopeRoot))
        // A task root: one duplicate, one same-name variant, one file-name conflict, one new note.
        try f.write([
            "branches.md": f.note("branches", "feat/ prefix"),
            "branch-rule.md": f.note("branches", "feat/ prefix, lowercase"),
            "deploy.md": f.note("deploy", "use make deploy"),
            "MEMORY.md": "- [Deploy](deploy.md) — make deploy\n- [Branches](branches.md) — feat/\n",
        ], into: f.memory(of: f.sandboxes + "/acme/old"))
        // A task whose record is gone, under the scope's sandboxes.
        try f.write(["ports.md": f.note("ports", "3000")], into: f.memory(of: f.sandboxes + "/acme/gone"))
        // Another clone of front.
        try f.write(["lint.md": f.note("lint", "pnpm lint"), "MEMORY.md": "- [Lint](lint.md) — pnpm lint\n"], into: f.memory(of: f.clone))
        // Not Scope's: left alone. Same for a folder whose name only contains "sandboxes".
        try f.write(["x.md": f.note("x", "x")], into: f.config + "/projects/-tmp-elsewhere/memory")
        try f.write(["y.md": f.note("y", "y")], into: f.config + "/projects/-tmp-scratch-scope-sandboxes-acme-z/memory")

        let plan = ClaudeMemoryRecovery.plan(locator: f.locator, sandboxesRoot: f.sandboxes, scopes: [f.scope],
                                             tasks: [f.task(slug: "old")], disk: f.disk)
        #expect(plan.targets.map(\.target.label) == ["@acme", "front"])
        let scope = try #require(plan.targets.first)
        #expect(scope.sources.map(\.origin) == [.taskRoot(nil), .taskRoot("old")])
        let old = scope.sources[1]
        #expect(old.files == [
            .init(file: "branch-rule.md", outcome: .sameName("branches.md")),
            .init(file: "branches.md", outcome: .identical("branches.md")),
            .init(file: "deploy.md", outcome: .copy),
        ])
        #expect(old.indexLines == ["- [Deploy](deploy.md) — make deploy"])
        #expect(scope.sources[0].indexLines == ["- [ports](ports.md) — about ports"])
        let front = plan.targets[1]
        #expect(front.sources.map(\.origin) == [.otherClone(f.clone)])
        #expect(plan.leftAlone == ["-tmp-elsewhere", "-tmp-scratch-scope-sandboxes-acme-z"])

        // The dry run wrote nothing.
        #expect(f.read(f.memory(of: f.scopeRoot) + "/deploy.md") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.memory(of: f.scopeRoot + "/front")))

        let applied = ClaudeMemoryRecovery.apply(plan, projects: f.projects)
        #expect(applied.copied == 3 && applied.skipped.isEmpty)
        #expect(f.read(f.memory(of: f.scopeRoot) + "/deploy.md") == f.note("deploy", "use make deploy"))
        #expect(f.read(f.memory(of: f.scopeRoot) + "/MEMORY.md")
                == "- [Branches](branches.md) — feat/\n- [ports](ports.md) — about ports\n- [Deploy](deploy.md) — make deploy\n")
        #expect(f.read(f.memory(of: f.scopeRoot + "/front") + "/MEMORY.md") == "- [Lint](lint.md) — pnpm lint\n")
        // Sources untouched, the same-name variant not copied.
        #expect(f.read(f.memory(of: f.sandboxes + "/acme/old") + "/branch-rule.md") != nil)
        #expect(f.read(f.memory(of: f.scopeRoot) + "/branch-rule.md") == nil)

        // A second pass has nothing left to copy.
        let again = ClaudeMemoryRecovery.plan(locator: f.locator, sandboxesRoot: f.sandboxes, scopes: [f.scope],
                                              tasks: [f.task(slug: "old")], disk: f.disk)
        #expect(again.targets.allSatisfy { $0.copies == 0 })
    }

    @Test func aTakenFileNameIsAConflictAndNothingIsOverwritten() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(atPath: f.base) }
        try f.write(["notes.md": f.note("mine", "target text")], into: f.memory(of: f.scopeRoot))
        try f.write(["notes.md": f.note("theirs", "other text")], into: f.memory(of: f.sandboxes + "/acme/old"))
        let plan = ClaudeMemoryRecovery.plan(locator: f.locator, sandboxesRoot: f.sandboxes, scopes: [f.scope],
                                             tasks: [f.task(slug: "old")], disk: f.disk)
        #expect(plan.targets.first?.sources.first?.files == [.init(file: "notes.md", outcome: .conflict)])
        let report = ClaudeMemoryRecovery.report(plan, home: f.base)
        #expect(report.contains("conflict  notes.md"))
        #expect(report.hasPrefix("Dry run"))
        _ = ClaudeMemoryRecovery.apply(plan, projects: f.projects)
        #expect(f.read(f.memory(of: f.scopeRoot) + "/notes.md") == f.note("mine", "target text"))
    }

    @Test func remotesCompareAcrossForms() {
        #expect(ClaudeMemoryRecovery.normalizedRemote("git@github.com:Acme/front.git") == "github.com/acme/front")
        #expect(ClaudeMemoryRecovery.normalizedRemote("https://github.com/acme/front") == "github.com/acme/front")
        #expect(ClaudeMemoryRecovery.normalizedRemote("https://token@github.com/acme/front.git/") == "github.com/acme/front")
        #expect(ClaudeMemoryRecovery.normalizedRemote("ssh://git@github.com/acme/front.git") == "github.com/acme/front")
    }

    /// The real report on this machine, read-only: `SCOPE_MEMORY_REPORT=1 swift test --filter ClaudeMemoryRecovery`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCOPE_MEMORY_REPORT"] == "1"))
    func reportOnThisMachine() throws {
        let home = NSHomeDirectory()
        let scopeHome = home + "/.scope"
        let configData = try Data(contentsOf: URL(fileURLWithPath: scopeHome + "/config.json"))
        let config = try #require(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let disk = ClaudeMemoryRecovery.Disk.live
        let scopes = (config["scopes"] as? [[String: Any]] ?? []).compactMap { scope -> ClaudeMemoryRecovery.Scope? in
            guard let root = scope["path"] as? String, let slug = scope["slug"] as? String else { return nil }
            let repos = (disk.children(root) ?? []).sorted().filter { FileManager.default.fileExists(atPath: root + "/" + $0 + "/.git") }
            return .init(slug: slug, name: scope["name"] as? String ?? slug, root: root,
                         repos: repos.map { .init(relativePath: $0, remote: disk.remote(root + "/" + $0)) })
        }
        // Decoded here rather than through `TaskRecordStore`, which may rewrite an old record: this test only reads.
        let decoder = JSONStore.makeDecoder()
        let taskFolder = scopeHome + "/tasks"
        let tasks = (disk.children(taskFolder) ?? []).filter { $0.hasSuffix(".json") }.compactMap { name in
            disk.read(taskFolder + "/" + name).flatMap { try? decoder.decode(TaskRecord.self, from: $0) }
        }
        let locator = ClaudeMemory.Locator(configDirectory: URL(fileURLWithPath: home + "/.claude"))
        let plan = ClaudeMemoryRecovery.plan(locator: locator, sandboxesRoot: scopeHome + "/sandboxes", scopes: scopes, tasks: tasks)
        print("records: \(tasks.count)\n" + ClaudeMemoryRecovery.report(plan))
    }
}
