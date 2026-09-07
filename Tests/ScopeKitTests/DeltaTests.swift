import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// Fixture: `api` with origin; a worktree on `scope/t1` holding one commit (adds `feature.swift`,
/// edits `README.md`), a dirty tracked file (`README.md` edited again), and an untracked file.
private struct DeltaFixture {
    let scope: TestScope
    let repo: URL
    let sandbox: URL
    let client: GitClient
    let baseSHA: String

    static func make() async throws -> DeltaFixture {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let baseSHA = try await client.output(["rev-parse", "HEAD"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")

        try scope.write(sandbox, "feature.swift", "let feature = true\n")
        try scope.write(sandbox, "README.md", "# api\ncommitted line\n")
        try await scope.commit(in: sandbox, "feat: feature")

        try scope.write(sandbox, "README.md", "# api\ncommitted line\nworking tree line\n")
        try scope.write(sandbox, "notes/todo.txt", "untracked\ntwo\n")
        try scope.write(sandbox, "blob.bin", "\u{0}\u{1}\u{2}binary")
        return DeltaFixture(scope: scope, repo: repo, sandbox: sandbox, client: client, baseSHA: baseSHA)
    }
}

@Suite(.serialized) struct DeltaTests {
    @Test func taskModeDiffsMergeBaseAgainstWorkingTreeIncludingUntracked() async throws {
        let f = try await DeltaFixture.make()
        let delta = try await Delta.load(mode: .task, in: f.sandbox, using: f.client)

        #expect(delta.mode == .task)
        #expect(delta.base == f.baseSHA)
        #expect(delta.ahead == 1 && delta.behind == 0)
        #expect(delta.files.map(\.path) == ["README.md", "blob.bin", "feature.swift", "notes/todo.txt"])

        let readme = delta.files[0]
        #expect(readme.status == .modified)
        #expect(readme.additions == 2 && readme.deletions == 0)   // committed + working tree lines
        #expect(readme.hunks[0].lines.filter { $0.kind == .addition }.map(\.text) == ["committed line", "working tree line"])

        #expect(delta.files[1].status == .binary && !delta.files[1].hasHunks)

        let feature = delta.files[2]
        #expect(feature.status == .added && feature.additions == 1)

        let untracked = delta.files[3]
        #expect(untracked.status == .added)
        #expect(untracked.additions == 2 && untracked.deletions == 0)
        #expect(untracked.hunks.count == 1)
        #expect(untracked.hunks[0].lines.map(\.text) == ["untracked", "two"])
        #expect(untracked.hunks[0].lines[1].newLineNumber == 2)

        #expect(delta.summary == DiffSummary(files: 4, additions: 5, deletions: 0))
    }

    @Test func uncommittedModeDiffsHeadAgainstWorkingTree() async throws {
        let f = try await DeltaFixture.make()
        let delta = try await Delta.load(mode: .uncommitted, in: f.sandbox, using: f.client)

        #expect(delta.base == "HEAD")
        #expect(delta.files.map(\.path) == ["README.md", "blob.bin", "notes/todo.txt"])   // feature.swift is committed
        #expect(delta.files[0].additions == 1 && delta.files[0].deletions == 0)
        #expect(delta.files[0].hunks[0].lines.last?.text == "working tree line")
        #expect(delta.files[2].status == .added && delta.files[2].additions == 2)
        #expect(delta.summary.additions == 3)
    }

    @Test func uncommittedModeOnCleanTreeIsEmpty() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let delta = try await Delta.load(mode: .uncommitted, in: repo, using: client)
        #expect(delta.files.isEmpty && delta.summary.isEmpty)
    }

    @Test func baseVsOriginCountsAndCommits() async throws {
        let f = try await DeltaFixture.make()

        // The sandbox is one commit ahead of origin/main.
        let fromSandbox = try await Delta.load(mode: .baseVsOrigin, in: f.sandbox, using: f.client)
        #expect(fromSandbox.base == "origin/main")
        #expect(fromSandbox.ahead == 1 && fromSandbox.behind == 0)
        #expect(fromSandbox.commitsAhead.map(\.subject) == ["feat: feature"])
        #expect(fromSandbox.commitsAhead[0].sha.count == 40)
        #expect(fromSandbox.commitsBehind.isEmpty)
        #expect(fromSandbox.files.isEmpty)

        // Push the task branch as main on origin: the base is now behind.
        let sandboxClient = await f.scope.client(for: f.sandbox)
        try await sandboxClient.run(["push", "-q", "origin", "scope/t1:main"])
        try await f.client.fetch()
        let fromBase = try await Delta.load(mode: .baseVsOrigin, in: f.repo, using: f.client, defaultBranch: "main")
        #expect(fromBase.ahead == 0 && fromBase.behind == 1)
        #expect(fromBase.commitsBehind.map(\.subject) == ["feat: feature"])
    }

    @Test func taskModeFallsBackToLocalDefaultBranchWithoutOrigin() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api", withOrigin: false)
        let client = await scope.client(for: repo)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "main")
        try scope.write(sandbox, "x.txt", "x\n")
        try await scope.commit(in: sandbox, "x")

        let delta = try await Delta.load(mode: .task, in: sandbox, using: client)
        #expect(delta.files.map(\.path) == ["x.txt"])
        #expect(delta.ahead == 1)
    }
}
