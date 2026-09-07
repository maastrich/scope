import Foundation
import Testing
@testable import ScopeGit

@Suite struct GitWorktreeParserTests {
    @Test func mainAndBranchWorktrees() {
        let output = """
        worktree /Users/me/src/api
        HEAD 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
        branch refs/heads/main

        worktree /Users/me/.scope/sandboxes/acme/demo/api
        HEAD 0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a
        branch refs/heads/scope/demo

        """
        let worktrees = GitWorktree.parse(output)
        #expect(worktrees.count == 2)
        #expect(worktrees[0] == GitWorktree(
            path: "/Users/me/src/api", head: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b", branch: "main"
        ))
        #expect(worktrees[1].path == "/Users/me/.scope/sandboxes/acme/demo/api")
        #expect(worktrees[1].branch == "scope/demo")   // refs/heads/ stripped, nested name kept
        #expect(!worktrees[1].isDetached)
    }

    @Test func detachedWorktree() {
        let output = """
        worktree /tmp/detached
        HEAD 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
        detached
        """
        let worktrees = GitWorktree.parse(output)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].isDetached)
        #expect(worktrees[0].branch == nil)
        #expect(worktrees[0].head == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b")
    }

    @Test func bareLockedAndPrunable() {
        let output = """
        worktree /srv/git/api.git
        bare

        worktree /tmp/locked
        HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        branch refs/heads/wip
        locked reason with spaces

        worktree /tmp/locked-no-reason
        HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        branch refs/heads/other
        locked

        worktree /tmp/gone
        HEAD cccccccccccccccccccccccccccccccccccccccc
        detached
        prunable gitdir file points to non-existent location
        """
        let worktrees = GitWorktree.parse(output)
        #expect(worktrees.count == 4)

        #expect(worktrees[0].isBare)
        #expect(worktrees[0].head == nil)
        #expect(worktrees[0].branch == nil)

        #expect(worktrees[1].isLocked)
        #expect(worktrees[1].lockReason == "reason with spaces")
        #expect(worktrees[1].branch == "wip")

        #expect(worktrees[2].isLocked)
        #expect(worktrees[2].lockReason == nil)

        #expect(worktrees[3].isPrunable)
        #expect(worktrees[3].isDetached)
        #expect(!worktrees[3].isLocked)
    }

    @Test func emptyAndWhitespaceOutput() {
        #expect(GitWorktree.parse("").isEmpty)
        #expect(GitWorktree.parse("\n\n").isEmpty)
    }

    @Test func recordWithoutWorktreeLineIsDropped() {
        let output = """
        HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        branch refs/heads/orphan

        worktree /tmp/real
        HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        branch refs/heads/main
        """
        let worktrees = GitWorktree.parse(output)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].path == "/tmp/real")
    }

    @Test func unknownKeysAreIgnored() {
        let output = """
        worktree /tmp/x
        HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        branch refs/heads/main
        future-key some value
        """
        let worktrees = GitWorktree.parse(output)
        #expect(worktrees == [GitWorktree(path: "/tmp/x", head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", branch: "main")])
    }
}
