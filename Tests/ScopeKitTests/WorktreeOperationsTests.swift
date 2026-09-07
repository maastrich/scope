import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

@Suite(.serialized) struct WorktreeOperationsTests {
    @Test func createWorktreeFromOriginDefaultThenReuseBranch() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)

        #expect(await client.hasRemote())
        #expect(await client.defaultBranch() == "main")
        #expect(await client.refExists("origin/main"))
        #expect(!(await client.branchExists("scope/t1")))

        try await client.fetch()
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
        #expect(scope.exists(sandbox.appending(path: "README.md")))
        #expect(await client.branchExists("scope/t1"))
        let facts = await RepoFacts.load(for: repo, using: client, includeWorktrees: true)
        #expect(facts.worktrees.contains { $0.branch == "scope/t1" })

        // Remove, then add again on the existing branch (no -b, no start point needed).
        try await client.removeWorktree(at: sandbox)
        #expect(!scope.exists(sandbox))
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: nil)
        #expect(scope.exists(sandbox.appending(path: "README.md")))
    }

    @Test func missingStartPointForNewBranchIsTyped() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api", withOrigin: false)
        let client = await scope.client(for: repo)
        await #expect(throws: WorktreeError.missingStartPoint(branch: "scope/x")) {
            try await client.createWorktree(at: scope.root.appending(path: "sb"), branch: "scope/x", from: nil)
        }
        #expect(!(await client.hasRemote()))
    }

    @Test func removeRefusesDirtyWorktreeUnlessForced() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")

        #expect(try await client.hasUncommittedChanges(at: sandbox) == false)
        try scope.write(sandbox, "notes.txt", "untracked\n")
        #expect(try await client.hasUncommittedChanges(at: sandbox) == true)

        await #expect(throws: WorktreeError.uncommittedChanges(path: sandbox.path)) {
            try await client.removeWorktree(at: sandbox)
        }
        #expect(scope.exists(sandbox))
        try await client.removeWorktree(at: sandbox, force: true)
        #expect(!scope.exists(sandbox))
    }

    @Test func pruneDropsRecordsOfDeletedFolders() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
        try FileManager.default.removeItem(at: sandbox)

        var facts = await RepoFacts.load(for: repo, using: client, includeWorktrees: true)
        #expect(facts.worktrees.contains { $0.branch == "scope/t1" && $0.isPrunable })
        try await client.prune()
        facts = await RepoFacts.load(for: repo, using: client, includeWorktrees: true)
        #expect(!facts.worktrees.contains { $0.branch == "scope/t1" })

        // removeWorktree on a folder that is already gone prunes instead of failing.
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: nil)
        try FileManager.default.removeItem(at: sandbox)
        try await client.removeWorktree(at: sandbox)
    }

    @Test func deleteBranchNeedsForceWhenUnmerged() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
        try scope.write(sandbox, "feature.txt", "x\n")
        try await scope.commit(in: sandbox, "feature")
        try await client.removeWorktree(at: sandbox)

        await #expect(throws: GitError.self) { try await client.deleteBranch(name: "scope/t1") }
        #expect(await client.branchExists("scope/t1"))
        try await client.deleteBranch(name: "scope/t1", force: true)
        #expect(!(await client.branchExists("scope/t1")))
    }

    @Test func mergeBaseAndAheadBehind() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let base = try await client.output(["rev-parse", "HEAD"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
        try scope.write(sandbox, "a.txt", "a\n")
        try await scope.commit(in: sandbox, "a")
        try scope.write(sandbox, "b.txt", "b\n")
        try await scope.commit(in: sandbox, "b")

        #expect(try await client.mergeBase("origin/main", "scope/t1") == base)
        let counts = try await client.aheadBehind("scope/t1", "origin/main")
        #expect(counts.ahead == 2 && counts.behind == 0)
    }

    @Test func commitAllAndPushToOrigin() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
        let sandboxClient = await scope.client(for: sandbox)

        await #expect(throws: PublishError.nothingToCommit) { try await sandboxClient.commitAll(message: "empty") }
        try scope.write(sandbox, "a.txt", "a\n")
        let sha = try await sandboxClient.commitAll(message: "feat: a")
        #expect(sha.count == 40)
        #expect(try await client.hasUncommittedChanges(at: sandbox) == false)

        try await sandboxClient.push()
        #expect(await client.refExists("origin/scope/t1"))
        #expect(try await sandboxClient.output(["rev-parse", "--abbrev-ref", "@{upstream}"]) == "origin/scope/t1")
    }

    @Test func ghClientHelpers() {
        #expect(GhClient.lastURL(in: "Creating pull request…\nhttps://github.com/acme/api/pull/12\n")?.absoluteString == "https://github.com/acme/api/pull/12")
        #expect(GhClient.lastURL(in: "nothing here") == nil)
        #expect(GhClient.locate(environment: ["PATH": "/nonexistent"]) == nil || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh"))
    }
}
