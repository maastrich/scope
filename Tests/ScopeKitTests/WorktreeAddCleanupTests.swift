import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// A `worktree add` whose checkout dies half-way — here a required filter whose program is not on `PATH`, the way a
/// Git LFS repository fails when git cannot find `git-lfs` — leaves nothing behind, so a retry takes the same path.
@Suite(.serialized) struct WorktreeAddCleanupTests {
    /// A repository whose checkout needs the filter `x`, run by a program no `PATH` has.
    private func repoWithMissingFilter(_ scope: TestScope) async throws -> (URL, GitClient) {
        let repo = try await scope.makeRepo("api")
        try scope.write(repo, ".gitattributes", "*.bin filter=x\n")
        try scope.write(repo, "data.bin", "payload\n")
        try await scope.commit(in: repo, "data")
        let client = await scope.client(for: repo)
        try await client.run(["push", "-q", "origin", "main"])
        try await client.run(["config", "filter.x.process", "scope-missing-filter-\(UUID().uuidString.prefix(8))"])
        try await client.run(["config", "filter.x.required", "true"])
        return (repo, client)
    }

    @Test func failedAddOfNewBranchRemovesBranchFolderAndRecord() async throws {
        let scope = try await TestScope.make()
        let (repo, client) = try await repoWithMissingFilter(scope)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)

        await #expect(throws: GitError.self) {
            try await client.createWorktree(at: sandbox, branch: "feat/map", from: "origin/main")
        }
        #expect(!(await client.branchExists("feat/map")))
        #expect(!scope.exists(sandbox))
        let facts = await RepoFacts.load(for: repo, using: client, includeWorktrees: true)
        #expect(facts.worktrees.count == 1)

        // Fixed: the retry creates the branch again (the `-b` path) and checks out.
        try await client.run(["config", "--unset", "filter.x.required"])
        try await client.run(["config", "--unset", "filter.x.process"])
        try await client.createWorktree(at: sandbox, branch: "feat/map", from: "origin/main")
        #expect(scope.exists(sandbox.appending(path: "data.bin")))
        #expect(await client.branchExists("feat/map"))
    }

    @Test func failedAddNeverDeletesABranchThatExistedBefore() async throws {
        let scope = try await TestScope.make()
        let (_, client) = try await repoWithMissingFilter(scope)
        try await client.run(["branch", "feat/map", "origin/main"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)

        await #expect(throws: GitError.self) {
            try await client.createWorktree(at: sandbox, branch: "feat/map", from: "origin/main")
        }
        #expect(await client.branchExists("feat/map"))
        #expect(!scope.exists(sandbox))
        #expect(await client.worktreePath(ofBranch: "feat/map") == nil)
    }

    @Test func failedAddLeavesAnOccupiedFolderAlone() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try scope.write(sandbox, "mine.txt", "keep me\n")

        await #expect(throws: GitError.self) {
            try await client.createWorktree(at: sandbox, branch: "feat/map", from: "origin/main")
        }
        #expect(scope.exists(sandbox.appending(path: "mine.txt")))
        #expect(!(await client.branchExists("feat/map")))
    }

    @Test func failedAddEmptiesAFolderThatWasEmpty() async throws {
        let scope = try await TestScope.make()
        let (_, client) = try await repoWithMissingFilter(scope)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        await #expect(throws: GitError.self) {
            try await client.createWorktree(at: sandbox, branch: "feat/map", from: "origin/main")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.path).isEmpty)
        #expect(!(await client.branchExists("feat/map")))
    }
}
