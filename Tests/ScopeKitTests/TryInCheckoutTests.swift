import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// A task's branch tried in the user's own checkout and put back (spec §4.5), on real repositories: the stash,
/// the detached HEAD, the refusals, the refresh, and the put back that keeps a conflicting stash.
@Suite(.serialized) struct TryInCheckoutTests {
    /// A base repo on `main` with a task worktree on `feat/x` holding one commit.
    private func fixture() async throws -> (scope: TestScope, client: GitClient, base: URL, sandbox: URL) {
        let scope = try await TestScope.make()
        let base = try await scope.makeRepo("api")
        try scope.write(base, "shared.txt", "base\n")
        try await scope.commit(in: base, "add shared")
        let client = await scope.client(for: base)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "feat/x", from: "main")
        try scope.write(sandbox, "feature.txt", "feature\n")
        try await scope.commit(in: sandbox, "feature work")
        return (scope, client, base, sandbox)
    }

    private func head(_ client: GitClient, _ ref: String = "HEAD") async throws -> String {
        try await client.output(["rev-parse", ref])
    }

    private func currentBranch(_ client: GitClient) async throws -> String {
        try await client.output(["rev-parse", "--abbrev-ref", "HEAD"])
    }

    @Test func aCleanBaseIsDetachedOntoTheBranchAndPutBack() async throws {
        let (scope, client, base, _) = try await fixture()
        let mainHead = try await head(client)
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-1")
        #expect(checkout.previousBranch == "main" && checkout.previousHead == mainHead && checkout.stashSHA == nil)
        #expect(checkout.head == (try await head(client, "feat/x")))
        // Detached: the user's branch itself did not move.
        #expect(try await currentBranch(client) == "HEAD")
        #expect(try await head(client, "main") == mainHead)
        #expect(scope.exists(base.appending(path: "feature.txt")))

        #expect(try await client.endTry(checkout, editsLabel: "scope-try-edits-t") == .restored)
        #expect(try await currentBranch(client) == "main")
        #expect(try await head(client) == mainHead)
        #expect(!scope.exists(base.appending(path: "feature.txt")))
        #expect(try await client.hasUncommittedChanges(at: base) == false)
    }

    @Test func uncommittedChangesAreStashedAndComeBack() async throws {
        let (scope, client, base, _) = try await fixture()
        try scope.write(base, "shared.txt", "edited in base\n")
        try scope.write(base, "notes.txt", "untracked\n")
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-2")
        let sha = try #require(checkout.stashSHA)
        #expect(await client.stashExists(sha))
        // The tree is the task's: the edit is gone, the untracked file too.
        #expect(try String(contentsOf: base.appending(path: "shared.txt"), encoding: .utf8) == "base\n")
        #expect(!scope.exists(base.appending(path: "notes.txt")))
        #expect(try await client.output(["stash", "list", "--format=%gs"]).contains("scope-try-t-2"))

        #expect(try await client.endTry(checkout, editsLabel: "scope-try-edits-t") == .restored)
        #expect(try await currentBranch(client) == "main")
        #expect(try String(contentsOf: base.appending(path: "shared.txt"), encoding: .utf8) == "edited in base\n")
        #expect(try String(contentsOf: base.appending(path: "notes.txt"), encoding: .utf8) == "untracked\n")
        #expect(await client.stashExists(sha) == false)
    }

    @Test func aConflictingStashIsKeptNeverLost() async throws {
        let (scope, client, base, sandbox) = try await fixture()
        try scope.write(base, "shared.txt", "edited in base\n")
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-3")
        let sha = try #require(checkout.stashSHA)
        // While trying, main moves on the same lines the stash touches: the put back cannot apply it cleanly.
        try scope.write(sandbox, "shared.txt", "moved on main\n")
        try await scope.commit(in: sandbox, "main side")
        try await client.run(["branch", "-f", "main", "feat/x"])

        let outcome = try await client.endTry(checkout, editsLabel: "scope-try-edits-t")
        #expect(outcome == .stashKept(sha: sha))
        #expect(try await currentBranch(client) == "main")
        #expect(await client.stashExists(sha))
        _ = scope
    }

    @Test func editsMadeWhileTryingAreStashedAside() async throws {
        let (scope, client, base, _) = try await fixture()
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-4")
        try scope.write(base, "feature.txt", "tweaked while trying\n")
        #expect(try await client.endTry(checkout, editsLabel: "scope-try-edits-t-4") == .restored)
        #expect(try await currentBranch(client) == "main")
        #expect(try await client.hasUncommittedChanges(at: base) == false)
        #expect(try await client.output(["stash", "list", "--format=%gs"]).contains("scope-try-edits-t-4"))
    }

    @Test func refreshFollowsTheBranchHead() async throws {
        let (scope, client, base, sandbox) = try await fixture()
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-5")
        try scope.write(sandbox, "more.txt", "more\n")
        try await scope.commit(in: sandbox, "more work")
        let newHead = try await head(client, "feat/x")
        #expect(checkout.head != newHead)
        #expect(try await client.refreshTry(branch: "feat/x") == newHead)
        #expect(try await head(client) == newHead)
        #expect(try await currentBranch(client) == "HEAD")
        #expect(scope.exists(base.appending(path: "more.txt")))
        // A dirty base that does not overlap is fast-forwarded with its edit kept.
        try scope.write(base, "local.txt", "kept\n")
        try scope.write(sandbox, "even-more.txt", "x\n")
        try await scope.commit(in: sandbox, "even more")
        #expect(try await client.refreshTry(branch: "feat/x") == (try await head(client, "feat/x")))
        #expect(scope.exists(base.appending(path: "local.txt")))
        #expect(try await client.endTry(checkout, editsLabel: "scope-try-edits-t-5") == .restored)
    }

    @Test func anOperationInProgressOrConflictsRefuse() async throws {
        let (scope, client, base, _) = try await fixture()
        // A merge that stops: conflicts in the tree and MERGE_HEAD on disk.
        try await client.run(["switch", "-q", "-c", "other"])
        try scope.write(base, "shared.txt", "other side\n")
        try await scope.commit(in: base, "other")
        try await client.run(["switch", "-q", "main"])
        try scope.write(base, "shared.txt", "main side\n")
        try await scope.commit(in: base, "main")
        _ = try await client.run(["merge", "other"], allowFailure: true)
        #expect(await client.operationInProgress() == "merge")
        await #expect(throws: TryError.operationInProgress("merge")) {
            try await client.beginTry(branch: "feat/x", label: "scope-try-t-6")
        }
        #expect(try await currentBranch(client) == "main")
        try await client.run(["merge", "--abort"])
        await #expect(throws: TryError.branchMissing("feat/nope")) {
            try await client.beginTry(branch: "feat/nope", label: "scope-try-t-6")
        }
    }

    @Test func aDeletedBranchGoesBackToTheCommit() async throws {
        let (scope, client, _, _) = try await fixture()
        try await client.run(["switch", "-q", "-c", "temp"])
        let tempHead = try await head(client)
        let checkout = try await client.beginTry(branch: "feat/x", label: "scope-try-t-7")
        #expect(checkout.previousBranch == "temp")
        try await client.run(["branch", "-D", "temp"])
        #expect(try await client.endTry(checkout, editsLabel: "scope-try-edits-t-7") == .restored)
        #expect(try await currentBranch(client) == "HEAD")
        #expect(try await head(client) == tempHead)
        _ = scope
    }

    @Test func stashLabelsNameTheTask() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(GitClient.tryStashLabel(task: "auth-cache", at: date).hasPrefix("scope-try-auth-cache-2025"))
        #expect(GitClient.tryEditsStashLabel(task: "auth-cache", at: date).hasPrefix("scope-try-edits-auth-cache-2025"))
        #expect(!GitClient.tryStashLabel(task: "x", at: date).contains(":"))
    }
}
