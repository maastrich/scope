import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite(.serialized) struct TaskGitWatchTests {
    @Test func resolvesTheWorktreeAndItsSharedGitDirectory() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")

        let watch = TaskGitWatch.resolve(sandboxes: [sandbox], branches: ["scope/t1", "scope/t1"])
        let common = TaskGitWatch.canonical(repo.appending(path: ".git"))
        #expect(watch.commonDirectories == [common])
        #expect(watch.gitDirectories.count == 1)
        #expect(watch.gitDirectories[0].hasPrefix(common + "/worktrees/"))
        #expect(watch.branches == ["scope/t1"])
        #expect(watch.watchedDirectories.map(\.path) == [common])
    }

    @Test func aSandboxWithoutGitIsSkipped() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        #expect(TaskGitWatch.resolve(sandboxes: [nowhere], branches: ["b"]).commonDirectories.isEmpty)
    }

    @Test func onlyTheTasksOwnGitStateIsRelevant() {
        let watch = TaskGitWatch(gitDirectories: ["/r/.git/worktrees/t1"], commonDirectories: ["/r/.git"],
                                 branches: ["scope/t1"])
        // This worktree's index and HEAD: a commit, a checkout, a reset.
        #expect(watch.relevance(of: "/r/.git/worktrees/t1/index") == true)
        #expect(watch.relevance(of: "/r/.git/worktrees/t1/HEAD") == true)
        #expect(watch.relevance(of: "/r/.git/worktrees/t1/logs/HEAD") == false)
        // Another task's worktree of the same repository.
        #expect(watch.relevance(of: "/r/.git/worktrees/t2/index") == false)
        // The branch moved, was packed, or was pushed.
        #expect(watch.relevance(of: "/r/.git/refs/heads/scope/t1") == true)
        #expect(watch.relevance(of: "/r/.git/refs/heads/scope/t1.lock") == true)
        #expect(watch.relevance(of: "/r/.git/refs/heads/scope/t10") == false)
        #expect(watch.relevance(of: "/r/.git/refs/heads/main") == false)
        #expect(watch.relevance(of: "/r/.git/packed-refs") == true)
        #expect(watch.relevance(of: "/r/.git/refs/remotes/origin/scope/t1") == true)
        // Noise.
        #expect(watch.relevance(of: "/r/.git/objects/ab/cdef") == false)
        #expect(watch.relevance(of: "/r/.git/index") == false)
        // Not a watched git directory at all: the caller's rules apply.
        #expect(watch.relevance(of: "/sandboxes/task/api/main.swift") == nil)
        #expect(watch.relevance(of: "/r/.gitignore") == nil)
    }
}
