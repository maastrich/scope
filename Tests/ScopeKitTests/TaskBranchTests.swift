import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// Several branches in one task (spec §4.3): a repository of a task carries secondary worktrees, each on a branch of
/// its own, managed like the primary one — added and removed on demand, salvaged and rebuilt with the task.
@Suite(.serialized) struct TaskBranchTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    // MARK: Record

    @Test func aRecordWrittenBeforeWorktreesReadsAsOnePerRepository() throws {
        let json = """
        {"version":1,"id":"0123456789ab","scopeID":"acme","scopeRoot":"/r","scopeSlug":"acme","name":"Old","slug":"old",
         "branch":"feat/old","root":"/h/sandboxes/acme/old",
         "repos":[{"repoRelativePath":"api","sandboxPath":"/h/sandboxes/acme/old/api","branch":"feat/old","state":"active"}],
         "createdAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TaskRecord.self, from: Data(json.utf8))
        #expect(record.repos[0].worktrees.isEmpty)
        #expect(!record.hasSecondaryWorktrees)
        #expect(record.sandboxes.map(\.sandboxKey) == ["api"])
        #expect(record.branches == ["feat/old"])
        // Written back without a key it never had: an older build reads the file untouched.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(!text.contains("worktrees"))
    }

    @Test func sandboxViewsNameEveryWorktreeAndTellThemApart() {
        var repo = TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api", branch: "feat/x")
        repo.worktrees = [TaskWorktree(branch: "fix/login", sandboxPath: "/t/api@login", base: "origin/main")]
        let record = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "T", slug: "t",
                                branch: "feat/x", root: "/t", repos: [repo])
        #expect(record.sandboxes.map(\.sandboxKey) == ["api", "api@fix/login"])
        #expect(record.sandboxes.map(\.isSecondary) == [false, true])
        #expect(record.branches == ["feat/x", "fix/login"])
        #expect(record.sandbox(repo: "api", branch: "fix/login")?.sandboxPath == "/t/api@login")
        #expect(record.sandbox(repo: "api", branch: "feat/x")?.isSecondary == false)
        #expect(record.sandbox(containing: "/t/api@login/src")?.branch == "fix/login")
        #expect(record.sandbox(containing: "/t/api/src")?.branch == "feat/x")
        #expect(record.additionalDirectories(forCwd: "/t/api@login") == ["/t/api"])
        #expect(record.sandboxes[1].sandboxLabel(scopeName: "acme") == "api · fix/login")
        #expect(record.hasSecondaryWorktrees)
    }

    @Test func secondaryFoldersSitBesideThePrimaryAndNeverCollide() {
        let primary = URL(fileURLWithPath: "/h/sandboxes/acme/t/api", isDirectory: true)
        #expect(TaskRepo.secondarySandboxURL(primary: primary, branch: "fix/login", taken: []).lastPathComponent == "api@login")
        // The short name is taken by another worktree of the task: the whole branch, slugified.
        #expect(TaskRepo.secondarySandboxURL(primary: primary, branch: "feat/login", taken: ["api@login"]).lastPathComponent == "api@feat-login")
        #expect(TaskRepo.secondarySandboxURL(primary: primary, branch: "feat/login", taken: ["api@login", "api@feat-login"]).lastPathComponent == "api@feat-login-2")
        // A repo scope task: the root is the primary sandbox, the others go next to it under the scope folder.
        let root = URL(fileURLWithPath: "/h/sandboxes/acme/viewed", isDirectory: true)
        #expect(TaskRepo.secondarySandboxURL(primary: root, branch: "docs/diff-view", taken: []).path == "/h/sandboxes/acme/viewed@diff-view")
    }

    @Test func checkpointRefsOfSecondaryWorktreesStayUnderTheTask() {
        let id = TaskID(rawValue: "0123456789ab")!
        var secondary = TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api@login", branch: "fix/login")
        secondary.isSecondary = true
        let ref = TaskCheckpoints.ref(task: id, number: 3, sandbox: secondary)
        #expect(ref == "refs/scope/checkpoints/0123456789ab/3-fix-login")
        #expect(TaskCheckpoints.taskID(ofRef: ref) == "0123456789ab")
        #expect(TaskCheckpoints.taskID(ofRef: "refs/scope/checkpoints/0123456789ab/3") == "0123456789ab")
        #expect(TaskCheckpoints.taskID(ofRef: "refs/scope/checkpoints/0123456789ab/x") == nil)
        #expect(TaskCheckpoints.repoPath(ofKey: "api@fix/login") == "api")
    }

    // MARK: Manager

    @Test func addingABranchMakesASecondWorktreeBesideThePrimary() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Login", branch: "feat/login", in: scope.declaration, repos: ["api"],
                                            scopeRepos: ["api", "web"], contextFiles: ["CLAUDE.md"])

        let record = try await manager.addBranch(task.id, branch: "fix/login-redirect", scopeRepos: ["api", "web"], contextFiles: ["CLAUDE.md"])
        let worktree = try #require(record.repos[0].worktrees.first)
        #expect(worktree.branch == "fix/login-redirect" && worktree.branchCreated == true && worktree.state == .active)
        #expect(worktree.sandboxPath == task.rootURL.appending(path: "api@login-redirect").filesystemPath)
        let sandbox = await scope.client(for: worktree.sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "fix/login-redirect")
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == (try await sandbox.output(["rev-parse", "origin/main"])))
        #expect(await scope.client(for: api).branchExists("fix/login-redirect"))
        // The new worktree reads the same context as the primary one, and git ignores it there.
        let context = try String(contentsOf: worktree.sandboxURL.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(context.hasPrefix(TaskProjection.generatedMarker))
        #expect(context.contains("Also on branch `fix/login-redirect`: `\(worktree.sandboxPath)`"))
        #expect(context.contains("scope task branch add"))
        #expect(try await sandbox.run(["status", "--porcelain"]).stdoutText.isEmpty)
        // The record says so once reloaded.
        let loaded = await TaskRecordStore(home: scope.home).loadAll().records
        #expect(loaded == [record])

        // The same branch twice, the task's own branch, and a reserved name are refused.
        await #expect(throws: TaskError.self) { try await manager.addBranch(task.id, branch: "fix/login-redirect") }
        await #expect(throws: TaskError.self) { try await manager.addBranch(task.id, branch: "feat/login") }
        await #expect(throws: TaskError.self) { try await manager.addBranch(task.id, branch: "scope/x") }
        // A task of several repositories needs the repository named.
        let multi = try await manager.create(name: "Both", branch: "feat/both", in: scope.declaration, repos: ["api", "web"])
        await #expect(throws: TaskError.self) { try await manager.addBranch(multi.id, branch: "fix/one") }
        let both = try await manager.addBranch(multi.id, branch: "fix/one", repo: "web")
        #expect(both.repo(at: "web")?.worktrees.map(\.branch) == ["fix/one"])
        #expect(both.repo(at: "api")?.worktrees.isEmpty == true)
    }

    @Test func aBranchCanStartFromAnExistingOne() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        try await client.run(["checkout", "-q", "-b", "feat/base"])
        try await client.run(["commit", "-q", "--allow-empty", "-m", "base work"])
        let head = try await client.output(["rev-parse", "HEAD"])
        try await client.run(["checkout", "-q", "main"])
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Stack", branch: "feat/stack", in: scope.declaration, repos: ["api"])

        // `--from`: a new branch, started where the existing one stands, under the name the caller chose.
        let record = try await manager.addBranch(task.id, branch: "feat/stack-2", startPoint: .startRef("feat/base"))
        let worktree = try #require(record.repos[0].worktrees.first)
        #expect(worktree.branch == "feat/stack-2" && worktree.branchCreated == true && worktree.base == "feat/base")
        let sandbox = await scope.client(for: worktree.sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == head)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/stack-2")
        // An existing branch can still be checked out as it is (a pull request's head goes the same way).
        let continued = try await manager.addBranch(task.id, branch: "ignored", startPoint: .existingBranch("feat/base"))
        let existing = try #require(continued.repos[0].worktrees.last)
        #expect(existing.branch == "feat/base" && existing.branchCreated == false)
        // A start that resolves to nothing is refused, and leaves no folder behind.
        await #expect(throws: TaskError.self) { try await manager.addBranch(task.id, branch: "feat/nowhere", startPoint: .startRef("feat/missing")) }
        #expect(!scope.exists(task.rootURL.appending(path: "api@nowhere")))
    }

    @Test func removingABranchSavesItsChangesAndKeepsTheBranch() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Login", branch: "feat/login", in: scope.declaration, repos: ["api"])
        let added = try await manager.addBranch(task.id, branch: "fix/typo")
        let worktree = try #require(added.repos[0].worktrees.first)
        try scope.write(worktree.sandboxURL, "note.txt", "unsaved\n")

        let (record, notices) = try await manager.removeBranch(task.id, branch: "fix/typo")
        #expect(record.repos[0].worktrees.isEmpty)
        #expect(!scope.exists(worktree.sandboxURL))
        #expect(scope.exists(task.repos[0].sandboxURL))
        let client = await scope.client(for: api)
        #expect(await client.branchExists("fix/typo"))
        guard case .changesSaved(let repo, let ref, _)? = notices.first else {
            Issue.record("expected the uncommitted note to be saved: \(notices)")
            return
        }
        #expect(repo == "api@fix/typo")
        #expect(try await client.output(["show", "\(ref):note.txt"]) == "unsaved")
        // The task branch is not a branch to remove.
        await #expect(throws: TaskError.self) { try await manager.removeBranch(task.id, branch: "feat/login") }
        await #expect(throws: TaskError.self) { try await manager.removeBranch(task.id, branch: "fix/typo") }
    }

    @Test func archiveSavesEveryWorktreeAndRestoreRebuildsThemAll() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Two", branch: "feat/two", in: scope.declaration, repos: ["api"])
        let added = try await manager.addBranch(task.id, branch: "docs/two")
        let secondary = try #require(added.repos[0].worktrees.first)
        try scope.write(added.repos[0].sandboxURL, "primary.txt", "p\n")
        try scope.write(secondary.sandboxURL, "secondary.txt", "s\n")

        let archived = try await manager.archive(task.id)
        #expect(archived.isArchived)
        #expect(archived.repos[0].state == .archived && archived.repos[0].salvageRef != nil)
        #expect(archived.repos[0].worktrees[0].state == .archived && archived.repos[0].worktrees[0].salvageRef != nil)
        #expect(archived.repos[0].worktrees[0].salvageRef != archived.repos[0].salvageRef)
        #expect(!scope.exists(task.rootURL) && !scope.exists(secondary.sandboxURL))
        let client = await scope.client(for: api)
        let twoKept = await client.branchExists("feat/two")
        let docsKept = await client.branchExists("docs/two")
        #expect(twoKept && docsKept)
        // Git's record of both worktrees is gone with them.
        #expect(await client.worktreePath(ofBranch: "docs/two") == nil)

        let restored = try await manager.reopen(task.id)
        #expect(!restored.isArchived)
        #expect(restored.repos[0].state == .active && restored.repos[0].salvageRef == nil)
        #expect(restored.repos[0].worktrees[0].state == .active && restored.repos[0].worktrees[0].salvageRef == nil)
        #expect(restored.repos[0].worktrees[0].sandboxPath == secondary.sandboxPath)
        #expect(try String(contentsOf: restored.repos[0].sandboxURL.appending(path: "primary.txt"), encoding: .utf8) == "p\n")
        #expect(try String(contentsOf: secondary.sandboxURL.appending(path: "secondary.txt"), encoding: .utf8) == "s\n")
        let sandbox = await scope.client(for: secondary.sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "docs/two")
    }

    @Test func closingWithTheBranchesDeletesEveryBranchOfTheTask() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Gone", branch: "feat/gone", in: scope.declaration, repos: ["api"])
        _ = try await manager.addBranch(task.id, branch: "fix/gone")
        try await manager.close(task.id, deleteBranch: true)
        let client = await scope.client(for: api)
        let goneDeleted = await client.branchExists("feat/gone")
        let fixDeleted = await client.branchExists("fix/gone")
        #expect(!goneDeleted && !fixDeleted)
        #expect(await manager.task(task.id) == nil)
    }

    @Test func aRepoScopeTaskKeepsItsOtherBranchesBesideItsRootAndTheCleanupLeavesThem() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo(".")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Viewed", branch: "feat/viewed", in: scope.declaration, repos: ["."])
        let added = try await manager.addBranch(task.id, branch: "docs/diff-view")
        let secondary = try #require(added.repos[0].worktrees.first)
        #expect(secondary.sandboxURL.deletingLastPathComponent().path == task.rootURL.deletingLastPathComponent().path)
        #expect(secondary.sandboxURL.lastPathComponent == "viewed@diff-view")
        #expect(added.sandbox(containing: secondary.sandboxPath)?.isSecondary == true)
        // The sibling folder is the task's: a cleanup with no grace period keeps it.
        let report = await manager.collectGarbage(grace: 0)
        #expect(report.removedFolders.isEmpty)
        #expect(scope.exists(secondary.sandboxURL))
        // Archived, it goes with the task, and comes back with it.
        let archived = try await manager.archive(task.id)
        #expect(!scope.exists(secondary.sandboxURL) && archived.repos[0].worktrees[0].state == .archived)
        let restored = try await manager.reopen(task.id)
        #expect(scope.exists(secondary.sandboxURL) && restored.repos[0].worktrees[0].state == .active)
    }

    @Test func checkpointsSnapshotEveryWorktreeUnderRefsOfTheirOwn() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Snap", branch: "feat/snap", in: scope.declaration, repos: ["api"])
        let record = try await manager.addBranch(task.id, branch: "fix/snap")
        let secondary = try #require(record.repos[0].worktrees.first)
        try scope.write(record.repos[0].sandboxURL, "a.txt", "a\n")
        try scope.write(secondary.sandboxURL, "b.txt", "b\n")

        let checkpoint = try #require(try await manager.checkpoints.snapshot(record, turn: nil))
        #expect(checkpoint.repos.map(\.repoRelativePath) == ["api", "api@fix/snap"])
        let client = await scope.client(for: api)
        let refs = try await client.output(["for-each-ref", "--format=%(refname)", TaskCheckpoints.namespace])
        #expect(refs.contains("\(task.id.rawValue)/1\n") || refs.hasSuffix("\(task.id.rawValue)/1"))
        #expect(refs.contains("\(task.id.rawValue)/1-fix-snap"))
        // Each snapshot holds its own worktree's file, not the other's.
        let primary = try #require(checkpoint.repos.first { $0.repoRelativePath == "api" })
        let other = try #require(checkpoint.repos.first { $0.repoRelativePath == "api@fix/snap" })
        #expect(try await client.output(["show", "\(primary.commit):a.txt"]) == "a")
        #expect((try? await client.output(["show", "\(primary.commit):b.txt"])) == nil)
        #expect(try await client.output(["show", "\(other.commit):b.txt"]) == "b")

        // Restoring puts each worktree's files back where they were.
        try scope.write(secondary.sandboxURL, "b.txt", "changed\n")
        _ = try await manager.checkpoints.restore(record, number: 1)
        #expect(try String(contentsOf: secondary.sandboxURL.appending(path: "b.txt"), encoding: .utf8) == "b\n")
        // A branch from the checkpoint is named after each worktree's own branch.
        _ = try await manager.checkpoints.branch(record, from: 1)
        let primaryBranched = await client.branchExists("feat/snap-cp1")
        let otherBranched = await client.branchExists("fix/snap-cp1")
        #expect(primaryBranched && otherBranched)
    }

    // MARK: Pull requests

    @Test func everyBranchOfTheTaskIsAskedAboutAndTheArchiveWaitsForAll() {
        var repo = TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api", branch: "feat/x")
        repo.worktrees = [TaskWorktree(branch: "docs/x", sandboxPath: "/t/api@x")]
        let record = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "T", slug: "t",
                                branch: "feat/x", root: "/t", repos: [repo])
        // The discovery asks about each sandbox's own branch: both of them, explicitly, reflog or not.
        #expect(record.activeSandboxes.map(\.branch) == ["feat/x", "docs/x"])
        #expect(record.sandboxes(onBranch: "docs/x").map(\.sandboxPath) == ["/t/api@x"])
        // One merged, the other open: the task stays until the second lands.
        #expect(MergedTaskArchive.decide(pullRequestStates: ["merged", "open"], threads: [], enabled: true, keptOpenAfterMerge: false) != .archive)
        #expect(MergedTaskArchive.decide(pullRequestStates: ["merged", "merged"], threads: [], enabled: true, keptOpenAfterMerge: false) == .archive)
        #expect(MergedTaskArchive.decide(pullRequestStates: ["merged", "closed"], threads: [], enabled: true, keptOpenAfterMerge: false) == .archive)
    }
}
