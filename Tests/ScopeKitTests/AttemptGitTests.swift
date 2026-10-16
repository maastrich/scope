import Foundation
import Testing
import ScopeCore
@testable import ScopeGit
@testable import ScopeTasks

/// The git side of best-of-N: attempt branches renamed back, two attempts diffed, a file carried across.
@Suite(.serialized) struct AttemptGitTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    private func makeAttempts(_ scope: TestScope, manager: TaskManager, count: Int = 2) async throws -> [TaskRecord] {
        var records: [TaskRecord] = []
        let group = UUID().uuidString
        for index in 1...count {
            records.append(try await manager.create(
                name: TaskAttempts.name(base: "Refresh tokens", index: index),
                branch: TaskAttempts.branch(base: "feat/refresh", index: index),
                slug: TaskAttempts.slug(base: "refresh", index: index),
                in: scope.declaration, repos: ["api"], topic: "Refresh tokens",
                attempt: TaskAttempt(group: group, index: index, count: count, baseName: "Refresh tokens", baseBranch: "feat/refresh")
            ))
        }
        return records
    }

    @Test func movingABranchRenamesItUnderTheWorktree() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "feat/x-a2", from: "origin/main")
        try await client.run(["-C", sandbox.path, "push", "-q", "-u", "origin", "feat/x-a2"])

        try await client.moveBranch(from: "feat/x-a2", to: "feat/x", in: sandbox)
        #expect(try await client.output(["-C", sandbox.path, "rev-parse", "--abbrev-ref", "HEAD"]) == "feat/x")
        #expect(await client.branchExists("feat/x"))
        #expect(!(await client.branchExists("feat/x-a2")))
        // The upstream named the old branch on the remote: dropped, so a push does not go there by surprise.
        let upstream = try await client.run(["-C", sandbox.path, "rev-parse", "--abbrev-ref", "feat/x@{upstream}"], allowFailure: true)
        #expect(!upstream.succeeded)
    }

    @Test func movingOntoAnExistingBranchIsRefused() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        try await client.run(["branch", "feat/x"])
        let sandbox = scope.root.appending(path: "sb/api", directoryHint: .isDirectory)
        try await client.createWorktree(at: sandbox, branch: "feat/x-a1", from: "origin/main")
        await #expect(throws: GitError.self) { try await client.moveBranch(from: "feat/x-a1", to: "feat/x", in: sandbox) }
        #expect(await client.branchExists("feat/x-a1"))
    }

    @Test func compareDiffsTwoBranchesFromEitherWorktree() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let client = await scope.client(for: api)
        let a1 = scope.root.appending(path: "sb/a1", directoryHint: .isDirectory)
        let a2 = scope.root.appending(path: "sb/a2", directoryHint: .isDirectory)
        try await client.createWorktree(at: a1, branch: "feat/x-a1", from: "origin/main")
        try await client.createWorktree(at: a2, branch: "feat/x-a2", from: "origin/main")
        try scope.write(a1, "lib.swift", "let one = 1\n")
        try await scope.commit(in: a1, "one")
        try scope.write(a2, "lib.swift", "let two = 2\n")
        try scope.write(a2, "extra.swift", "// extra\n")
        try await scope.commit(in: a2, "two")

        let files = try await Delta.compare(from: "feat/x-a1", to: "feat/x-a2", in: a1, using: client)
        #expect(files.map(\.path) == ["extra.swift", "lib.swift"])
        #expect(files[0].status == .added)
        #expect(files[1].additions == 1 && files[1].deletions == 1)
        let reversed = try await Delta.compare(from: "feat/x-a2", to: "feat/x-a1", in: a2, using: client)
        #expect(reversed.first { $0.path == "extra.swift" }?.status == .deleted)
    }

    @Test func keepingAnAttemptGivesItTheBriefsNameAndBranchBack() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let attempts = try await makeAttempts(scope, manager: manager)
        #expect(attempts.map(\.branch) == ["feat/refresh-a1", "feat/refresh-a2"])

        let kept = try await manager.keepAttempt(attempts[1].id, otherBranches: ["feat/refresh-a1"])
        #expect(kept.name == "Refresh tokens")
        #expect(kept.branch == "feat/refresh")
        #expect(kept.repos[0].branch == "feat/refresh")
        #expect(kept.attempt == nil)
        #expect(kept.topic == nil)
        #expect(kept.attemptsKept?.count == 2)
        #expect(kept.attemptsKept?.otherBranches == ["feat/refresh-a1"])
        let client = await scope.client(for: api)
        #expect(try await client.output(["-C", kept.repos[0].sandboxPath, "rev-parse", "--abbrev-ref", "HEAD"]) == "feat/refresh")
        #expect(await client.branchExists("feat/refresh-a1"))
        // Persisted: a reload sees the plain name.
        let reloaded = makeManager(scope)
        _ = await reloaded.loadAll()
        let reloadedBranch = await reloaded.task(kept.id)?.branch
        #expect(reloadedBranch == "feat/refresh")

        await #expect(throws: TaskError.self) { try await manager.keepAttempt(attempts[0].id, otherBranches: []) }
    }

    @Test func aTaskThatIsNotAnAttemptCannotBeKept() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let plain = try await manager.create(name: "Plain", branch: "feat/plain", in: scope.declaration, repos: ["api"])
        await #expect(throws: TaskError.self) { try await manager.keepAttempt(plain.id, otherBranches: []) }
    }

    @Test func salvagingBeforeACopyKeepsTheTargetsChanges() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let attempts = try await makeAttempts(scope, manager: manager)
        let target = attempts[0].repos[0].sandboxURL
        #expect(try await manager.salvageChanges(of: attempts[0].id).isEmpty)
        try scope.write(target, "notes.md", "mine\n")
        let refs = try await manager.salvageChanges(of: attempts[0].id)
        let ref = try #require(refs["api"])
        #expect(ref.hasPrefix("refs/scope/salvage/refresh-a1-"))
        let client = await scope.client(for: api)
        #expect(try await client.output(["show", "\(ref):notes.md"]) == "mine")
        // The working tree is untouched: the file is still there to be overwritten.
        #expect(scope.exists(target.appending(path: "notes.md")))
    }

    @Test func aFileIsCopiedOrDeletedAcrossAttempts() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let attempts = try await makeAttempts(scope, manager: manager)
        let source = attempts[1].repos[0].sandboxURL
        let target = attempts[0].repos[0].sandboxURL
        try scope.write(source, "src/new.swift", "// from attempt 2\n")
        try scope.write(target, "src/old.swift", "// only here\n")

        #expect(try AttemptFileCopy.copy("src/new.swift", from: source, to: target) == .copied(bytes: 18))
        #expect(try String(contentsOf: target.appending(path: "src/new.swift"), encoding: .utf8) == "// from attempt 2\n")
        #expect(try AttemptFileCopy.copy("src/old.swift", from: source, to: target) == .deleted)
        #expect(!scope.exists(target.appending(path: "src/old.swift")))
        #expect(throws: AttemptFileCopy.Refusal.missingOnBothSides("nope.txt")) {
            try AttemptFileCopy.copy("nope.txt", from: source, to: target)
        }
        #expect(throws: AttemptFileCopy.Refusal.unsafePath("../escape")) {
            try AttemptFileCopy.copy("../escape", from: source, to: target)
        }
        #expect(throws: AttemptFileCopy.Refusal.unsafePath(".git/config")) {
            try AttemptFileCopy.copy(".git/config", from: source, to: target)
        }
        #expect(throws: AttemptFileCopy.Refusal.isDirectory("src")) {
            try AttemptFileCopy.copy("src", from: source, to: target)
        }
        // A link in the target's path would send the copy outside the sandbox.
        try FileManager.default.createSymbolicLink(at: target.appending(path: "out"), withDestinationURL: scope.root)
        try scope.write(source, "out/x.txt", "x\n")
        #expect(throws: AttemptFileCopy.Refusal.throughSymlink("out/x.txt")) {
            try AttemptFileCopy.copy("out/x.txt", from: source, to: target)
        }
    }
}
