import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// What a merged task's sandbox would lose with it, on real repositories: a squash-merged branch whose remote was
/// deleted and pruned loses nothing; a commit past the merged head, or never pushed, is counted.
@Suite(.serialized) struct UnpushedCommitsTests {
    /// A repo with `origin`, and a task worktree on `feat/x` with one commit.
    private func fixture() async throws -> (scope: TestScope, client: GitClient, sandbox: URL) {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        try await client.run(["push", "-q", "origin", "main"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "feat/x", from: "origin/main")
        try scope.write(sandbox, "feature.txt", "feature\n")
        try await scope.commit(in: sandbox, "feature work")
        return (scope, client, sandbox)
    }

    private func head(_ client: GitClient, _ sandbox: URL) async throws -> String {
        try await client.output(["-C", sandbox.filesystemPath, "rev-parse", "HEAD"])
    }

    @Test func aMergedHeadWhoseRemoteBranchWasPrunedLosesNothing() async throws {
        let (scope, client, sandbox) = try await fixture()
        try await client.run(["-C", sandbox.filesystemPath, "push", "-q", "-u", "origin", "feat/x"])
        let merged = try await head(client, sandbox)
        // GitHub deletes the branch after the squash merge; the next fetch prunes it.
        try await client.run(["-C", sandbox.filesystemPath, "push", "-q", "origin", "--delete", "feat/x"])
        try await client.run(["-C", sandbox.filesystemPath, "fetch", "-q", "--prune", "origin"])
        #expect(await client.unpushedCommits(at: sandbox) == 1)
        #expect(await client.unpushedCommits(at: sandbox, pullRequestHeads: [merged]) == 0)
        _ = scope
    }

    @Test func aCommitPastTheMergedHeadIsCounted() async throws {
        let (scope, client, sandbox) = try await fixture()
        let merged = try await head(client, sandbox)
        try scope.write(sandbox, "after.txt", "after\n")
        try await scope.commit(in: sandbox, "after the merge")
        #expect(await client.unpushedCommits(at: sandbox, pullRequestHeads: [merged]) == 1)
        // A head this clone never saw is skipped, not a failure: the other one still counts.
        let unknown = String(repeating: "a", count: 40)
        #expect(await client.unpushedCommits(at: sandbox, pullRequestHeads: [unknown, merged]) == 1)
    }

    @Test func withoutAPullRequestTheUpstreamCounts() async throws {
        let (scope, client, sandbox) = try await fixture()
        try await client.run(["-C", sandbox.filesystemPath, "push", "-q", "-u", "origin", "feat/x"])
        #expect(await client.unpushedCommits(at: sandbox) == 0)
        try scope.write(sandbox, "more.txt", "more\n")
        try await scope.commit(in: sandbox, "not pushed")
        #expect(await client.unpushedCommits(at: sandbox) == 1)
    }

    @Test func withoutUpstreamWhatNoRemoteHasCounts() async throws {
        let (scope, client, sandbox) = try await fixture()
        _ = scope
        // Never pushed, no upstream: the one commit is on no remote.
        #expect(await client.unpushedCommits(at: sandbox) == 1)
        let unknown = String(repeating: "b", count: 40)
        #expect(await client.unpushedCommits(at: sandbox, pullRequestHeads: [unknown]) == 1)
    }
}
