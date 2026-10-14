import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite(.serialized) struct TaskGarbageCollectionTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    private func spawnSleep(in directory: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec sleep 60"]
        process.currentDirectoryURL = directory
        try process.run()
        return process
    }

    @Test func removesWhatNoLiveTaskOwnsAndKeepsTheRest() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let live = try await manager.create(name: "live", branch: "feat/live", in: scope.declaration, repos: ["api"])
        let gone = try await manager.create(name: "gone", branch: "feat/gone", in: scope.declaration, repos: ["api"])

        // A record lost while its worktree stayed: the folder is an orphan, git still lists the worktree, and
        // the work in it is saved before it goes.
        try FileManager.default.removeItem(at: scope.home.appending(path: "tasks/\(gone.fileName)"))
        try scope.write(gone.repos[0].sandboxURL, "lost.txt", "work\n")
        let reloaded = makeManager(scope)
        _ = await reloaded.loadAll()
        let fresh = manager.scopeSandboxesURL(scopeSlug: scope.declaration.slug).appending(path: "being-created")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let stray = try spawnSleep(in: gone.rootURL)
        let worker = try spawnSleep(in: live.rootURL)
        defer { worker.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        let old = Date.now.addingTimeInterval(3_600)
        let preview = await reloaded.collectGarbage(dryRun: true, now: old)
        #expect(preview.removedFolders.count == 2)   // `gone` and `being-created`, both older than the grace now
        #expect(scope.exists(gone.rootURL) && stray.isRunning)

        let report = await reloaded.collectGarbage()
        #expect(report.removedFolders.isEmpty)       // nothing is past the grace yet: just created
        #expect(scope.exists(gone.rootURL) && stray.isRunning)

        let done = await reloaded.collectGarbage(now: old)
        #expect(Set(done.removedFolders.map { URL(fileURLWithPath: $0).lastPathComponent }) == [gone.slug, "being-created"])
        #expect(done.stoppedProcesses.contains { $0.contains("\(stray.processIdentifier)") })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!stray.isRunning && worker.isRunning)
        #expect(!scope.exists(gone.rootURL) && scope.exists(live.rootURL))
        let worktrees = try await scope.client(for: api).output(["worktree", "list", "--porcelain"])
        #expect(!worktrees.contains(gone.slug) && worktrees.contains(live.slug))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: ScopeHome.trashURL(home: scope.home).path)) ?? []).isEmpty)
        let saved = try #require(done.savedChanges.first?.split(separator: " ").last.map(String.init))
        #expect(try await scope.client(for: api).output(["show", "\(saved):lost.txt"]) == "work")
    }

    @Test func anUnreadableRecordKeepsEveryFolder() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "kept", branch: "feat/kept", in: scope.declaration, repos: ["api"])
        try FileManager.default.removeItem(at: scope.home.appending(path: "tasks/\(task.fileName)"))
        try Data("{ broken".utf8).write(to: scope.home.appending(path: "tasks/0123456789ab.json"))
        let reloaded = makeManager(scope)
        _ = await reloaded.loadAll()

        let report = await reloaded.collectGarbage(now: .now.addingTimeInterval(3_600))
        #expect(report.removedFolders.isEmpty && scope.exists(task.rootURL))
    }

    @Test func salvageRefsExpireUnlessARecordNeedsThem() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let kept = try await manager.create(name: "kept", branch: "feat/kept", in: scope.declaration, repos: ["api"])
        let dropped = try await manager.create(name: "dropped", branch: "feat/dropped", in: scope.declaration, repos: ["api"])
        try scope.write(kept.repos[0].sandboxURL, "a.txt", "a\n")
        try scope.write(dropped.repos[0].sandboxURL, "b.txt", "b\n")
        let archived = try await manager.archive(kept.id)
        try await manager.close(dropped.id, deleteBranch: false)

        let later = Date.now.addingTimeInterval(31 * 86_400)
        let report = await manager.collectGarbage(now: later)
        let base = await scope.client(for: api)
        let refs = try await base.output(["for-each-ref", "--format=%(refname)", "refs/scope/salvage"])
        #expect(report.deletedRefs.count == 1 && report.deletedRefs[0].contains("dropped"))
        #expect(refs.contains(try #require(archived.repos[0].salvageRef)) && !refs.contains("dropped"))
    }

    @Test func listsTasksWhoseCleanupNeverFinished() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let web = try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "stuck", branch: "feat/stuck", in: scope.declaration, repos: ["api", "web"])
        let parked = web.deletingLastPathComponent().appending(path: "web-parked")
        _ = try? await manager.dismantle(task.id, .archive) { try? FileManager.default.moveItem(at: web, to: parked) }

        let report = await manager.collectGarbage(now: .now.addingTimeInterval(3_600))
        #expect(report.pendingTasks == [task.id])
        // Its folder is the pending run's to finish, not the collector's.
        #expect(report.removedFolders.isEmpty && scope.exists(task.repos[1].sandboxURL))
    }
}
