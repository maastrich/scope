import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite(.serialized) struct TaskManagerTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    @Test func existingBranchStartPointContinuesItInsteadOfBranching() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        // A branch someone already pushed work to, back on main afterwards.
        try await client.run(["checkout", "-q", "-b", "feat/half-done"])
        try await client.run(["commit", "-q", "--allow-empty", "-m", "wip"])
        let head = try await client.output(["rev-parse", "HEAD"])
        try await client.run(["checkout", "-q", "main"])
        let manager = makeManager(scope)

        let task = try await manager.create(
            name: "Finish it", branch: "ignored/name", initialPrompt: "finish feat/half-done",
            in: scope.declaration, repos: ["api"], startPoint: .existingBranch("feat/half-done")
        )
        // The start point owns the branch: the caller's name is not used and nothing new was created.
        #expect(task.branch == "feat/half-done")
        let sandbox = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/half-done")
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == head)
    }

    @Test func aBranchCheckedOutElsewhereIsRefusedWithItsPath() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        try await client.run(["checkout", "-q", "-b", "feat/busy"])
        let manager = makeManager(scope)

        await #expect(throws: TaskError.self) {
            try await manager.create(
                name: "Busy", branch: "feat/busy", in: scope.declaration, repos: ["api"],
                startPoint: .existingBranch("feat/busy")
            )
        }
        // The base checkout is untouched and no sandbox was left behind.
        #expect(try await client.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/busy")
        #expect(!scope.exists(scope.home.appending(path: "sandboxes/acme/busy")))
    }

    @Test func createMultiRepoTaskProjectsFilesAndWorktrees() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        try await scope.makeRepo("docs")
        let manager = makeManager(scope)

        let task = try await manager.create(
            name: "Auth Refresh (v2)!", branch: "feat/auth-refresh-v2", initialPrompt: "Add a refresh-token flow.\n",
            in: scope.declaration, repos: ["api", "web"], scopeRepos: ["api", "web", "docs"]
        )
        #expect(task.slug == "auth-refresh-v2")
        #expect(task.prompt == "Add a refresh-token flow.")
        #expect(task.branch == "feat/auth-refresh-v2")
        #expect(task.root == scope.home.appending(path: "sandboxes/acme/auth-refresh-v2").path)
        #expect(task.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(task.repos.allSatisfy { $0.state == .active && $0.branch == task.branch })
        #expect(!task.isMonoRepo)
        #expect(task.threadCwd == task.rootURL)
        #expect(manager.threadCwd(for: task) == task.rootURL)
        #expect(manager.taskEnvironment(for: task) == ["SCOPE_TASK": "auth-refresh-v2", "SCOPE_TASK_ROOT": task.root,
                                                      "SCOPE_PORT": String(PortAllocator.range.lowerBound)])

        // Worktrees on the task branch, started from origin/main.
        for repo in task.repos {
            #expect(scope.exists(repo.sandboxURL.appending(path: "README.md")))
            let client = await scope.client(for: repo.sandboxURL)
            #expect(try await client.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/auth-refresh-v2")
            #expect(try await client.output(["rev-parse", "HEAD"]) == (try await client.output(["rev-parse", "origin/main"])))
        }
        let apiFacts = await RepoFacts.load(for: api, using: scope.client(for: api), includeWorktrees: true)
        // git lists worktrees by realpath (`/private/var/…` for a `/var/…` temp dir): compare resolved paths.
        let resolvedSandbox = task.repos[0].sandboxURL.resolvingSymlinksInPath().path
        #expect(apiFacts.worktrees.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedSandbox && $0.branch == "feat/auth-refresh-v2" })

        // AGENTS.md
        let agents = try String(contentsOf: task.contextFileURL, encoding: .utf8)
        #expect(agents.hasPrefix(TaskProjection.generatedMarker))
        #expect(agents.contains("# Task: Auth Refresh (v2)!"))
        #expect(agents.contains("Branch: `feat/auth-refresh-v2`"))
        #expect(agents.contains("## Goal\n\nAdd a refresh-token flow.\n"))
        #expect(agents.contains("**api** — sandbox: `\(task.repos[0].sandboxPath)`"))
        #expect(agents.contains("**web** — sandbox: `\(task.repos[1].sandboxPath)`"))
        #expect(agents.contains("## Other repositories of the scope\n\nNot part of this task. Ask before adding one to the task.\n\n- docs\n"))
        #expect(agents.contains("Never modify the base checkouts under `\(scope.scopeRoot.path)`"))

        // .code-workspace
        let workspace = try JSONSerialization.jsonObject(with: Data(contentsOf: task.workspaceURL)) as? [String: Any]
        let folders = workspace?["folders"] as? [[String: String]]
        #expect(folders == [["name": "api", "path": "api"], ["name": "web", "path": "web"]])

        // Persisted and reloadable.
        let store = TaskRecordStore(home: scope.home)
        let loaded = await store.loadAll()
        #expect(loaded.records == [task] && loaded.problems.isEmpty)
        let fresh = makeManager(scope)
        #expect(await fresh.loadAll().isEmpty)
        #expect(await fresh.tasks(in: scope.declaration.id) == [task])
    }

    @Test func slugsAreUniquePerScope() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let first = try await manager.create(name: "Fix login", branch: "fix/login", in: scope.declaration, repos: ["api"])
        let second = try await manager.create(name: "Fix login again", branch: "fix/login-2", slug: "fix-login", in: scope.declaration, repos: ["api"])
        #expect(first.slug == "fix-login" && second.slug == "fix-login-2")
        #expect(second.branch == "fix/login-2")   // the branch is the caller's, no prefix logic
        await #expect(throws: TaskError.self) { try await manager.create(name: "x", branch: "scope/x", in: scope.declaration, repos: ["api"]) }
        await #expect(throws: TaskError.self) { try await manager.create(name: "x", branch: " ", in: scope.declaration, repos: ["api"]) }
        #expect(scope.exists(second.rootURL.appending(path: "api/README.md")))
        // A leftover folder under sandboxes/<scope>/ also counts as taken.
        try FileManager.default.createDirectory(at: scope.home.appending(path: "sandboxes/acme/fix-login-3"), withIntermediateDirectories: true)
        let third = try await manager.create(name: "Fix login", branch: "fix/login-3", in: scope.declaration, repos: ["api"])
        #expect(third.slug == "fix-login-4")
    }

    @Test func singleRepoTaskUsesSandboxAsThreadCwd() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "one", branch: "feat/one", in: scope.declaration, repos: ["api"],
                                            contextFiles: ["CLAUDE.md"])
        #expect(task.threadCwd.path == task.repos[0].sandboxPath)
        #expect(scope.exists(task.workspaceURL))
        // One repository: the thread starts in the sandbox, so both files are written there, not at the root
        // the driver never opens.
        for name in ["AGENTS.md", "CLAUDE.md"] {
            #expect(scope.exists(task.repos[0].sandboxURL.appending(path: name)))
            #expect(!scope.exists(task.rootURL.appending(path: name)))
        }
    }

    @Test func addRepoCreatesSandboxAndRegeneratesProjection() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "grow", branch: "feat/grow", in: scope.declaration, repos: ["api"],
                                            scopeRepos: ["api", "web"], contextFiles: ["CLAUDE.md"])
        #expect(try String(contentsOf: task.contextFileURL, encoding: .utf8).contains("- web\n"))

        let grown = try await manager.addRepo(task.id, repo: "web", scopeRepos: ["api", "web"], contextFiles: ["CLAUDE.md"])
        #expect(grown.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(scope.exists(grown.repos[1].sandboxURL.appending(path: "README.md")))
        #expect(grown.threadCwd == grown.rootURL)
        let agents = try String(contentsOf: grown.contextFileURL, encoding: .utf8)
        #expect(agents.contains("**web**") && !agents.contains("## Other repositories"))
        let workspace = try String(contentsOf: grown.workspaceURL, encoding: .utf8)
        #expect(workspace.contains("\"path\" : \"web\""))
        // The cwd moved from the sandbox up to the task root: the copies left behind are gone, so no agent
        // reads a projection that lists one repository when the task now has two.
        for name in ["AGENTS.md", "CLAUDE.md"] {
            #expect(scope.exists(grown.rootURL.appending(path: name)))
            #expect(!scope.exists(grown.repos[0].sandboxURL.appending(path: name)))
        }

        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "web") }
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "missing") }
        #expect(await manager.task(task.id) == grown)
    }

    @Test func closeGuardrailsThenForce() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "close me", branch: "feat/close-me", in: scope.declaration, repos: ["api", "web"])
        let webSandbox = task.repos[1].sandboxURL
        try scope.write(webSandbox, "wip.txt", "dirty\n")

        do {
            try await manager.close(task.id, deleteBranch: true)
            Issue.record("close should refuse a dirty sandbox")
        } catch let error as TaskError {
            guard case .uncommittedChanges(let repo) = error else { Issue.record("unexpected \(error)"); return }
            #expect(repo == "web")
        }
        // Nothing was removed: the api sandbox (clean) is still there.
        #expect(scope.exists(task.repos[0].sandboxURL) && scope.exists(webSandbox))

        // Commit the change: clean, but the branch is now unmerged → branch guardrail.
        try await scope.commit(in: webSandbox, "wip")
        do {
            try await manager.close(task.id, deleteBranch: true)
            Issue.record("close should refuse to delete an unmerged branch")
        } catch let error as TaskError {
            guard case .branchNotMerged(let repo, let branch) = error else { Issue.record("unexpected \(error)"); return }
            #expect(repo == "web" && branch == "feat/close-me")
        }
        #expect(await manager.task(task.id) != nil)   // record kept for a retry
        let webClient = await scope.client(for: scope.scopeRoot.appending(path: "web"))
        #expect(await webClient.branchExists("feat/close-me"))

        try await manager.close(task.id, deleteBranch: true, force: true)
        #expect(await manager.task(task.id) == nil)
        #expect(!(await webClient.branchExists("feat/close-me")))
        #expect(!(await scope.client(for: api).branchExists("feat/close-me")))
        #expect(!scope.exists(task.rootURL))
        #expect(await TaskRecordStore(home: scope.home).loadAll().records.isEmpty)
    }

    @Test func archiveRemovesSandboxesKeepsBranchesAndRecord() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "park", branch: "feat/park", in: scope.declaration, repos: ["api"])
        try scope.write(task.repos[0].sandboxURL, "x.txt", "x\n")
        try await scope.commit(in: task.repos[0].sandboxURL, "x")

        let archived = try await manager.archive(task.id)
        #expect(archived.isArchived && archived.repos[0].state == .archived)
        #expect(!scope.exists(task.repos[0].sandboxURL) && !scope.exists(task.rootURL))
        #expect(await scope.client(for: api).branchExists("feat/park"))
        #expect(await TaskRecordStore(home: scope.home).loadAll().records == [archived])
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "api") }

        // Close after archive: worktrees are gone, only the branch and the record remain.
        try await manager.close(task.id, deleteBranch: true, force: true)
        #expect(!(await scope.client(for: api).branchExists("feat/park")))
    }

    @Test func monoRepoTaskRootIsTheSandboxAndCarriesTheContextFiles() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo(".")
        let manager = makeManager(scope)

        let task = try await manager.create(name: "solo", branch: "feat/solo", in: scope.declaration, repos: ["."])
        #expect(task.isMonoRepo)
        #expect(task.repos[0].sandboxPath == task.root)
        #expect(task.threadCwd == task.rootURL)
        #expect(scope.exists(task.rootURL.appending(path: "README.md")))
        // The thread starts here, so the context file is here — excluded from git, so the delta stays clean.
        #expect(scope.exists(task.contextFileURL))
        #expect(!scope.exists(task.workspaceURL))
        let cwdClient = await scope.client(for: task.threadCwd)
        #expect(try await cwdClient.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/solo")
        await #expect(throws: TaskError.self) { try await manager.create(name: "bad", branch: "feat/bad", in: scope.declaration, repos: [".", "api"]) }
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "sub") }

        // Every driver's file name, one content, all excluded.
        try await manager.regenerateProjection(task.id, contextFiles: ["CLAUDE.md", "AGENTS.md", "CLAUDE.md"])
        let claude = task.contextFileURL(named: "CLAUDE.md")
        #expect(scope.exists(claude))
        #expect(try String(contentsOf: claude, encoding: .utf8) == (try String(contentsOf: task.contextFileURL, encoding: .utf8)))
        let excludeRaw = try await cwdClient.output(["rev-parse", "--git-path", "info/exclude"])
        let exclude = excludeRaw.hasPrefix("/") ? URL(fileURLWithPath: excludeRaw) : task.rootURL.appending(path: excludeRaw)
        #expect(try String(contentsOf: exclude, encoding: .utf8).contains("/AGENTS.md"))
        #expect(try String(contentsOf: exclude, encoding: .utf8).contains("/CLAUDE.md"))
        let baseClient = await scope.client(for: scope.scopeRoot)
        #expect(try await baseClient.hasUncommittedChanges(at: task.rootURL) == false)
        let delta = try await Delta.load(mode: .uncommitted, in: task.rootURL, using: baseClient)
        #expect(delta.files.isEmpty)

        // A file Scope did not generate is never overwritten, and the exclude is not duplicated. Scope's own
        // file is refreshed in place.
        try "mine".write(to: task.contextFileURL, atomically: true, encoding: .utf8)
        try await manager.regenerateProjection(task.id, contextFiles: ["CLAUDE.md"])
        #expect(try String(contentsOf: task.contextFileURL, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: claude, encoding: .utf8).hasPrefix(TaskProjection.generatedMarker))
        #expect(try String(contentsOf: exclude, encoding: .utf8).components(separatedBy: "/AGENTS.md").count == 2)

        // The repository's own CLAUDE.md: the context goes to CLAUDE.local.md, which Claude Code reads beside it.
        let local = task.contextFileURL(named: "CLAUDE.local.md")
        try "ours".write(to: claude, atomically: true, encoding: .utf8)
        try await manager.regenerateProjection(task.id, contextFiles: ["CLAUDE.md"])
        #expect(try String(contentsOf: claude, encoding: .utf8) == "ours")
        #expect(try String(contentsOf: local, encoding: .utf8).hasPrefix(TaskProjection.generatedMarker))
        #expect(try String(contentsOf: exclude, encoding: .utf8).contains("/CLAUDE.local.md"))

        // Once the repository's file is gone the context returns to CLAUDE.md, and the companion goes with it so
        // the agent never reads the context twice.
        try FileManager.default.removeItem(at: claude)
        try await manager.regenerateProjection(task.id, contextFiles: ["CLAUDE.md"])
        #expect(try String(contentsOf: claude, encoding: .utf8).hasPrefix(TaskProjection.generatedMarker))
        #expect(!scope.exists(local))

        // Archive removes the worktree (= the root); close deletes the branch.
        try await manager.archive(task.id)
        #expect(!scope.exists(task.rootURL))
        try await manager.close(task.id, deleteBranch: true)
        #expect(!(await baseClient.branchExists("feat/solo")))
    }

    @Test func createWithoutOriginFallsBackToLocalDefault() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("local", withOrigin: false)
        let manager = makeManager(scope)
        let task = try await manager.create(name: "offline", branch: "feat/offline", in: scope.declaration, repos: ["local"])
        let client = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await client.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/offline")
        #expect(try await client.output(["rev-parse", "HEAD"]) == (try await client.output(["rev-parse", "main"])))
    }

    @Test func failedCreateRollsBackEarlierSandboxes() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        await #expect(throws: TaskError.self) {
            try await manager.create(name: "broken", branch: "feat/broken", in: scope.declaration, repos: ["api", "nope"])
        }
        let client = await scope.client(for: api)
        #expect(!(await client.branchExists("feat/broken")))
        #expect(!scope.exists(scope.home.appending(path: "sandboxes/acme/broken")))
        #expect(await manager.tasks(in: scope.declaration.id).isEmpty)
    }
}
