import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// A task branch against `origin/main`, on real repositories: behind, conflicts without touching the tree, the
/// rebase that lands and the one that stops and restores.
@Suite(.serialized) struct BranchLagTests {
    /// A repo with `origin`, a task worktree on `feat/x` with one commit, and `k` commits pushed to `origin/main`
    /// after the fork — one of them touching `shared.txt` when `conflicting`.
    private func fixture(mainCommits: Int = 2, conflicting: Bool = false) async throws -> (scope: TestScope, client: GitClient, sandbox: URL) {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        try scope.write(repo, "shared.txt", "base\n")
        try await scope.commit(in: repo, "add shared")
        let client = await scope.client(for: repo)
        try await client.run(["push", "-q", "origin", "main"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "feat/x", from: "origin/main")
        try scope.write(sandbox, "feature.txt", "feature\n")
        if conflicting { try scope.write(sandbox, "shared.txt", "feature side\n") }
        try await scope.commit(in: sandbox, "feature work")
        // main moves on the base, pushed: the sandbox only learns of it through a fetch.
        for index in 0..<mainCommits {
            if conflicting, index == 0 {
                try scope.write(repo, "shared.txt", "main side\n")
            } else {
                try scope.write(repo, "main-\(index).txt", "\(index)\n")
            }
            try await scope.commit(in: repo, index == 0 ? "feat: first (#\(41 + index))" : "Merge pull request #\(41 + index) from acme/other")
        }
        try await client.run(["push", "-q", "origin", "main"])
        return (scope, client, sandbox)
    }

    @Test func behindCountsAndNamesTheMergedPullRequests() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 2)
        _ = scope
        let lag = try await client.branchLag(at: sandbox)
        #expect(lag.upstream == "origin/main")
        #expect(lag.behind == 2 && lag.ahead == 1)
        #expect(lag.conflicts.isEmpty && lag.conflictsKnown)
        #expect(lag.mergedPullRequests == [42, 41])
        #expect(lag.upstreamHead == (try await client.output(["rev-parse", "origin/main"])))
    }

    /// Both sides changed one file in places that merge cleanly: no conflict, but an overlap worth updating for.
    @Test func filesBothSidesChangedAreTheOverlap() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 1)
        #expect(try await client.branchLag(at: sandbox).overlaps == [])
        let repo = URL(fileURLWithPath: try await client.output(["rev-parse", "--show-toplevel"]), isDirectory: true)
        // The same content on both sides merges cleanly.
        try scope.write(repo, "feature.txt", "feature\n")
        try await scope.commit(in: repo, "align feature")
        try await client.run(["push", "-q", "origin", "main"])
        let lag = try await client.branchLag(at: sandbox)
        #expect(lag.conflicts.isEmpty)
        #expect(lag.overlaps == ["feature.txt"])
    }

    @Test func aBranchThatContainsMainIsNotBehind() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 0)
        _ = scope
        let lag = try await client.branchLag(at: sandbox)
        #expect(lag.behind == 0 && lag.ahead == 1 && !lag.isBehind)
        #expect(lag.behindSubjects.isEmpty)
    }

    @Test func conflictsAreFoundWithoutTouchingTheWorktree() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 1, conflicting: true)
        let before = try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"])
        let lag = try await client.branchLag(at: sandbox)
        #expect(lag.behind == 1)
        #expect(lag.conflicts == ["shared.txt"] && lag.hasConflicts)
        // The dry merge left no trace: same head, clean tree, the feature's own text in place.
        #expect(try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"]) == before)
        #expect(try await client.hasUncommittedChanges(at: sandbox) == false)
        #expect(try String(contentsOf: sandbox.appending(path: "shared.txt"), encoding: .utf8) == "feature side\n")
        _ = scope
    }

    @Test func aCleanRebaseLandsAndCanBePushedWithLease() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 2)
        try await client.run(["-C", sandbox.filesystemPath, "push", "-q", "-u", "origin", "feat/x"])
        #expect(await client.isPublished("feat/x", at: sandbox))
        let before = try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"])
        let lag = try await client.branchLag(at: sandbox)
        guard case .rebased(let from, let to) = try await client.rebase(at: sandbox, onto: lag.upstream) else {
            Issue.record("a clean lag must rebase")
            return
        }
        #expect(from == before && to != before)
        let after = try await client.branchLag(at: sandbox, fetch: false)
        #expect(after.behind == 0 && after.ahead == 1)
        try await client.pushWithLease("feat/x", at: sandbox)
        #expect(try await client.output(["rev-parse", "origin/feat/x"]) == to)
        // Again: nothing to do.
        #expect(try await client.rebase(at: sandbox, onto: lag.upstream) == .upToDate)
        _ = scope
    }

    @Test func aRebaseThatStopsIsAbortedAndTheBranchRestored() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 1, conflicting: true)
        let before = try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"])
        let outcome = try await client.rebase(at: sandbox, onto: "origin/main")
        #expect(outcome == .conflicted(paths: ["shared.txt"]))
        #expect(try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"]) == before)
        #expect(try await client.hasUncommittedChanges(at: sandbox) == false)
        #expect(!scope.exists(sandbox.appending(path: ".git/rebase-merge")))
        #expect(try String(contentsOf: sandbox.appending(path: "shared.txt"), encoding: .utf8) == "feature side\n")
    }

    @Test func aDirtyTreeIsNeverRebased() async throws {
        let (scope, client, sandbox) = try await fixture(mainCommits: 1)
        try scope.write(sandbox, "wip.txt", "half done\n")
        let before = try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"])
        #expect(try await client.rebase(at: sandbox, onto: "origin/main") == .dirty)
        #expect(try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"]) == before)
        #expect(scope.exists(sandbox.appending(path: "wip.txt")))
    }

    @Test func pullRequestNumbersComeFromSquashAndMergeSubjects() {
        let subjects = ["feat: thing (#12)", "Merge pull request #7 from acme/x", "chore: no pr", "fix: other (#12)", "docs (#3) more"]
        #expect(BranchLag.pullRequestNumbers(in: subjects) == [12, 7])
        #expect(BranchLag.conflictedPaths(in: "abc123\na.txt\nb/c.txt\n\nAuto-merging a.txt\nCONFLICT (content)\n") == ["a.txt", "b/c.txt"])
        #expect(BranchLag.conflictedPaths(in: "abc123\n") == [])
    }
}
