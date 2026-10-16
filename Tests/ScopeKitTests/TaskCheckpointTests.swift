import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// Checkpoints per turn (spec §4.3): a snapshot of every sandbox under `refs/scope/checkpoints/<task>/<n>`, skipped
/// when nothing moved, restored with an undo, pruned at archive and by the cleanup.
@Suite(.serialized) struct TaskCheckpointTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    private func turn(_ n: Int, said: String? = nil) -> TaskCheckpoints.TurnInfo {
        TaskCheckpoints.TurnInfo(threadID: "3f9a2c17be04", threadTitle: "Claude Code", turn: n, endedAt: .now, said: said)
    }

    private func read(_ scope: TestScope, _ sandbox: URL, _ name: String) -> String? {
        try? String(contentsOf: sandbox.appending(path: name), encoding: .utf8)
    }

    @Test func aTurnLeavesACommitUnderItsRefAndAnUnchangedTreeLeavesNothing() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Rework auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        let client = await scope.client(for: api)
        let head = try await client.output(["-C", sandbox.path, "rev-parse", "HEAD"])

        try scope.write(sandbox, "a.txt", "one\ntwo\n")
        try scope.write(sandbox, "README.md", "# api\nmore\n")
        let first = try #require(try await manager.checkpoints.snapshot(task, turn: turn(1, said: "Added a.txt")))
        #expect(first.number == 1 && first.turn == 1 && first.threadTitle == "Claude Code" && first.said == "Added a.txt")
        #expect(first.additions == 3 && first.deletions == 0)
        let ref = TaskCheckpoints.ref(task: task.id, number: 1)
        #expect(ref == "refs/scope/checkpoints/\(task.id.rawValue)/1")
        #expect(try await client.output(["show", "\(ref):a.txt"]) == "one\ntwo")
        #expect(try await client.output(["log", "-1", "--format=%s", ref]).contains("turn 1 of Claude Code — Added a.txt"))
        // The branch did not move, the sandbox's own index is untouched (a.txt is still untracked there).
        #expect(try await client.output(["-C", sandbox.path, "rev-parse", "HEAD"]) == head)
        #expect(try await client.output(["-C", sandbox.path, "status", "--porcelain"]).contains("?? a.txt"))

        // Nothing moved: no checkpoint, the number is not consumed.
        #expect(try await manager.checkpoints.snapshot(task, turn: turn(2)) == nil)
        try scope.write(sandbox, "a.txt", "one\n")
        let second = try #require(try await manager.checkpoints.snapshot(task, turn: turn(3)))
        #expect(second.number == 2 && second.deletions == 1 && second.additions == 0)
        #expect(await manager.checkpoints.list(task.id).map(\.number) == [1, 2])
        #expect(TaskCheckpoints.taskID(ofRef: ref) == task.id.rawValue)
        #expect(TaskCheckpoints.taskID(ofRef: "refs/scope/salvage/x-y/changes-1") == nil)
    }

    @Test func restorePutsTheTreeBackAndCheckpointsWhatItReplaces() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Rework auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        let client = await scope.client(for: api)
        let head = try await client.output(["-C", sandbox.path, "rev-parse", "HEAD"])

        try scope.write(sandbox, "a.txt", "one\n")
        _ = try await manager.checkpoints.snapshot(task, turn: turn(1))
        try scope.write(sandbox, "a.txt", "two\n")
        try scope.write(sandbox, "b.txt", "new\n")
        try scope.write(sandbox, "README.md", "edited\n")

        let restoration = try await manager.checkpoints.restore(task, number: 1)
        #expect(restoration.restored.number == 1)
        let undo = try #require(restoration.undo)
        #expect(undo.number == 2 && undo.reason == .beforeRestore && undo.restoring == 1)
        #expect(read(scope, sandbox, "a.txt") == "one\n")
        #expect(read(scope, sandbox, "b.txt") == nil)
        #expect(read(scope, sandbox, "README.md") == "# api\n")
        #expect(try await client.output(["-C", sandbox.path, "rev-parse", "HEAD"]) == head)

        // The undo brings everything back, b.txt included; the restored tree, different from the last checkpoint, is kept too.
        let back = try await manager.checkpoints.restore(task, number: 2)
        #expect(back.undo?.number == 3 && back.undo?.reason == .beforeRestore)
        #expect(read(scope, sandbox, "a.txt") == "two\n" && read(scope, sandbox, "b.txt") == "new\n")
        #expect(read(scope, sandbox, "README.md") == "edited\n")
        await #expect(throws: TaskError.self) { try await manager.checkpoints.restore(task, number: 9) }

        let diff = try await manager.checkpoints.diff(task, number: 1)
        #expect(diff.count == 1 && Set(diff[0].files.map(\.path)) == ["README.md", "a.txt", "b.txt"])
        #expect(diff[0].files.first { $0.path == "b.txt" }?.status == .added)
    }

    @Test func aBranchIsMadeAtTheCheckpointWithoutCheckingItOut() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Rework auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        try scope.write(sandbox, "a.txt", "one\n")
        let checkpoint = try #require(try await manager.checkpoints.snapshot(task, turn: turn(1)))
        let name = try await manager.checkpoints.branch(task, from: 1)
        #expect(name == "feat/auth-cp1")
        let client = await scope.client(for: api)
        #expect(try await client.output(["rev-parse", name]) == checkpoint.repos[0].commit)
        #expect(try await client.output(["-C", sandbox.path, "branch", "--show-current"]) == "feat/auth")
        await #expect(throws: TaskError.self) { try await manager.checkpoints.branch(task, from: 1) }
    }

    @Test func theOldestGoAtFiftyAtArchiveAtCloseAndWhenNoRecordNamesThem() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Rework auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        let client = await scope.client(for: api)
        for n in 1...7 {
            try scope.write(sandbox, "a.txt", "\(n)\n")
            _ = try await manager.checkpoints.snapshot(task, turn: turn(n))
        }
        let pruned = await manager.checkpoints.prune(task, keep: 6)
        #expect(pruned.count == 1)
        #expect(await manager.checkpoints.list(task.id).map(\.number) == Array(2...7))
        func refs() async -> [String] {
            ((try? await client.output(["for-each-ref", "--format=%(refname)", TaskCheckpoints.namespace])) ?? "")
                .split(separator: "\n").map(String.init)
        }
        #expect(await refs().count == 6)

        _ = try await manager.dismantle(task.id, .archive)
        #expect(await manager.checkpoints.list(task.id).map(\.number) == Array(3...7))
        #expect(await refs().count == 5)

        // A ref of a task no record names: the cleanup's, once it is old enough — another build's live task looks
        // the same from here, and the snapshot (HEAD, here) is fresh.
        try await client.run(["update-ref", "refs/scope/checkpoints/0123456789ab/1", "HEAD"])
        let fresh = await manager.collectGarbage(dryRun: true)
        #expect(fresh.deletedRefs.isEmpty)
        let later = Date.now.addingTimeInterval(31 * 86_400)
        let preview = await manager.collectGarbage(dryRun: true, now: later)
        #expect(preview.deletedRefs.contains { $0.hasSuffix("refs/scope/checkpoints/0123456789ab/1") })
        #expect(await refs().count == 6)
        let report = await manager.collectGarbage(now: later)
        #expect(report.deletedRefs.count == 1)
        #expect(await refs().count == 5)

        _ = try await manager.dismantle(task.id, .close(deleteBranch: true))
        #expect(await refs().isEmpty)
        #expect(await manager.checkpoints.list(task.id).isEmpty)
    }

    @Test func theBaseCheckoutIsNeverSnapshotted() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        var task = try await manager.create(name: "Rework auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        task.repos[0].sandboxPath = api.path
        try scope.write(api, "a.txt", "one\n")
        #expect(try await manager.checkpoints.snapshot(task, turn: turn(1)) == nil)
        let client = await scope.client(for: api)
        #expect(try await client.output(["for-each-ref", TaskCheckpoints.namespace]).isEmpty)
    }
}
