import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite(.serialized) struct TaskManagerTests {
    private func makeManager(_ scope: TestScope, options: TaskManagerOptions = .init()) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home), options: options)
    }

    @Test func createMultiRepoTaskProjectsFilesAndWorktrees() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        try await scope.makeRepo("docs")
        let manager = makeManager(scope)

        let task = try await manager.create(name: "Auth Refresh (v2)!", in: scope.declaration, repos: ["api", "web"], scopeRepos: ["api", "web", "docs"])
        #expect(task.slug == "auth-refresh-v2")
        #expect(task.branch == "scope/auth-refresh-v2")
        #expect(task.root == scope.home.appending(path: "sandboxes/acme/auth-refresh-v2").path)
        #expect(task.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(task.repos.allSatisfy { $0.state == .active && $0.branch == task.branch })
        #expect(!task.isMonoRepo)
        #expect(task.threadCwd == task.rootURL)
        #expect(manager.threadCwd(for: task) == task.rootURL)
        #expect(manager.taskEnvironment(for: task) == ["SCOPE_TASK": "auth-refresh-v2", "SCOPE_TASK_ROOT": task.root])

        // Worktrees on the task branch, started from origin/main.
        for repo in task.repos {
            #expect(scope.exists(repo.sandboxURL.appending(path: "README.md")))
            let client = await scope.client(for: repo.sandboxURL)
            #expect(try await client.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "scope/auth-refresh-v2")
            #expect(try await client.output(["rev-parse", "HEAD"]) == (try await client.output(["rev-parse", "origin/main"])))
        }
        let apiFacts = await RepoFacts.load(for: api, using: scope.client(for: api), includeWorktrees: true)
        // git lists worktrees by realpath (`/private/var/…` for a `/var/…` temp dir): compare resolved paths.
        let resolvedSandbox = task.repos[0].sandboxURL.resolvingSymlinksInPath().path
        #expect(apiFacts.worktrees.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedSandbox && $0.branch == "scope/auth-refresh-v2" })

        // AGENTS.md
        let agents = try String(contentsOf: task.contextFileURL, encoding: .utf8)
        #expect(agents.hasPrefix(TaskProjection.generatedMarker))
        #expect(agents.contains("# Task: Auth Refresh (v2)!"))
        #expect(agents.contains("Branch: `scope/auth-refresh-v2`"))
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
        let first = try await manager.create(name: "Fix login", in: scope.declaration, repos: ["api"])
        let second = try await manager.create(name: "fix-login", in: scope.declaration, repos: ["api"])
        #expect(first.slug == "fix-login" && second.slug == "fix-login-2")
        #expect(second.branch == "scope/fix-login-2")
        #expect(scope.exists(second.rootURL.appending(path: "api/README.md")))
        // A leftover folder under sandboxes/<scope>/ also counts as taken.
        try FileManager.default.createDirectory(at: scope.home.appending(path: "sandboxes/acme/fix-login-3"), withIntermediateDirectories: true)
        let third = try await manager.create(name: "Fix login", in: scope.declaration, repos: ["api"])
        #expect(third.slug == "fix-login-4")
    }

    @Test func singleRepoTaskUsesSandboxAsThreadCwd() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "one", in: scope.declaration, repos: ["api"])
        #expect(task.threadCwd.path == task.repos[0].sandboxPath)
        #expect(scope.exists(task.contextFileURL) && scope.exists(task.workspaceURL))
    }

    @Test func addRepoCreatesSandboxAndRegeneratesProjection() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "grow", in: scope.declaration, repos: ["api"], scopeRepos: ["api", "web"])
        #expect(try String(contentsOf: task.contextFileURL, encoding: .utf8).contains("- web\n"))

        let grown = try await manager.addRepo(task.id, repo: "web", scopeRepos: ["api", "web"])
        #expect(grown.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(scope.exists(grown.repos[1].sandboxURL.appending(path: "README.md")))
        #expect(grown.threadCwd == grown.rootURL)
        let agents = try String(contentsOf: grown.contextFileURL, encoding: .utf8)
        #expect(agents.contains("**web**") && !agents.contains("## Other repositories"))
        let workspace = try String(contentsOf: grown.workspaceURL, encoding: .utf8)
        #expect(workspace.contains("\"path\" : \"web\""))

        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "web") }
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "missing") }
        #expect(await manager.task(task.id) == grown)
    }

    @Test func closeGuardrailsThenForce() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "close me", in: scope.declaration, repos: ["api", "web"])
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
            #expect(repo == "web" && branch == "scope/close-me")
        }
        #expect(await manager.task(task.id) != nil)   // record kept for a retry
        let webClient = await scope.client(for: scope.scopeRoot.appending(path: "web"))
        #expect(await webClient.branchExists("scope/close-me"))

        try await manager.close(task.id, deleteBranch: true, force: true)
        #expect(await manager.task(task.id) == nil)
        #expect(!(await webClient.branchExists("scope/close-me")))
        #expect(!(await scope.client(for: api).branchExists("scope/close-me")))
        #expect(!scope.exists(task.rootURL))
        #expect(await TaskRecordStore(home: scope.home).loadAll().records.isEmpty)
    }

    @Test func archiveRemovesSandboxesKeepsBranchesAndRecord() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "park", in: scope.declaration, repos: ["api"])
        try scope.write(task.repos[0].sandboxURL, "x.txt", "x\n")
        try await scope.commit(in: task.repos[0].sandboxURL, "x")

        let archived = try await manager.archive(task.id)
        #expect(archived.isArchived && archived.repos[0].state == .archived)
        #expect(!scope.exists(task.repos[0].sandboxURL) && !scope.exists(task.rootURL))
        #expect(await scope.client(for: api).branchExists("scope/park"))
        #expect(await TaskRecordStore(home: scope.home).loadAll().records == [archived])
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "api") }

        // Close after archive: worktrees are gone, only the branch and the record remain.
        try await manager.close(task.id, deleteBranch: true, force: true)
        #expect(!(await scope.client(for: api).branchExists("scope/park")))
    }

    @Test func monoRepoTaskRootIsTheSandboxAndContextFileIsOptIn() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo(".")
        let manager = makeManager(scope)

        let task = try await manager.create(name: "solo", in: scope.declaration, repos: ["."])
        #expect(task.isMonoRepo)
        #expect(task.repos[0].sandboxPath == task.root)
        #expect(task.threadCwd == task.rootURL)
        #expect(scope.exists(task.rootURL.appending(path: "README.md")))
        #expect(!scope.exists(task.contextFileURL))      // default: never pollute the sandbox
        #expect(!scope.exists(task.workspaceURL))
        let cwdClient = await scope.client(for: task.threadCwd)
        #expect(try await cwdClient.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "scope/solo")
        await #expect(throws: TaskError.self) { try await manager.create(name: "bad", in: scope.declaration, repos: [".", "api"]) }
        await #expect(throws: TaskError.self) { try await manager.addRepo(task.id, repo: "sub") }

        // Opt-in: AGENTS.md written once and excluded from git (the delta stays clean).
        await manager.setOptions(TaskManagerOptions(writeContextFileIntoMonoRepoSandbox: true))
        try await manager.regenerateProjection(task.id)
        #expect(scope.exists(task.contextFileURL))
        let excludeRaw = try await cwdClient.output(["rev-parse", "--git-path", "info/exclude"])
        let exclude = excludeRaw.hasPrefix("/") ? URL(fileURLWithPath: excludeRaw) : task.rootURL.appending(path: excludeRaw)
        #expect(try String(contentsOf: exclude, encoding: .utf8).contains("/AGENTS.md"))
        let baseClient = await scope.client(for: scope.scopeRoot)
        #expect(try await baseClient.hasUncommittedChanges(at: task.rootURL) == false)
        let delta = try await Delta.load(mode: .uncommitted, in: task.rootURL, using: baseClient)
        #expect(delta.files.isEmpty)

        // Existing user file is never overwritten; exclude is not duplicated.
        try "mine".write(to: task.contextFileURL, atomically: true, encoding: .utf8)
        try await manager.regenerateProjection(task.id)
        #expect(try String(contentsOf: task.contextFileURL, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: exclude, encoding: .utf8).components(separatedBy: "/AGENTS.md").count == 2)

        // Archive removes the worktree (= the root); close deletes the branch.
        try await manager.archive(task.id)
        #expect(!scope.exists(task.rootURL))
        try await manager.close(task.id, deleteBranch: true)
        #expect(!(await baseClient.branchExists("scope/solo")))
    }

    @Test func createWithoutOriginFallsBackToLocalDefault() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("local", withOrigin: false)
        let manager = makeManager(scope)
        let task = try await manager.create(name: "offline", in: scope.declaration, repos: ["local"])
        let client = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await client.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "scope/offline")
        #expect(try await client.output(["rev-parse", "HEAD"]) == (try await client.output(["rev-parse", "main"])))
    }

    @Test func failedCreateRollsBackEarlierSandboxes() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        await #expect(throws: TaskError.self) {
            try await manager.create(name: "broken", in: scope.declaration, repos: ["api", "nope"])
        }
        let client = await scope.client(for: api)
        #expect(!(await client.branchExists("scope/broken")))
        #expect(!scope.exists(scope.home.appending(path: "sandboxes/acme/broken")))
        #expect(await manager.tasks(in: scope.declaration.id).isEmpty)
    }
}
