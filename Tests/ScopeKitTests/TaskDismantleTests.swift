import Foundation
import Synchronization
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// Archive and close share one pipeline (`TaskManager.dismantle`): locked per task, persisted after each step,
/// safe to run again.
@Suite(.serialized) struct TaskDismantleTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    @Test func twoConcurrentArchivesBothSucceed() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "twice", branch: "feat/twice", in: scope.declaration, repos: ["api", "web"])

        async let first = manager.archive(task.id)
        async let second = manager.archive(task.id)
        let (a, b) = try await (first, second)

        #expect(a.isArchived && b.isArchived && a.archivedAt == b.archivedAt)
        #expect(!scope.exists(task.rootURL))
        #expect(await scope.client(for: api).branchExists("feat/twice"))
        #expect(await TaskRecordStore(home: scope.home).loadAll().records == [a])
    }

    @Test func concurrentRequestsPrepareOnceAndACloseWaitsForTheArchive() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "race", branch: "feat/race", in: scope.declaration, repos: ["api"])
        let prepared = Mutex(0)
        let prepare: @Sendable () async -> Void = { prepared.withLock { $0 += 1 } }

        async let first = manager.dismantle(task.id, .archive, prepare: prepare)
        async let second = manager.dismantle(task.id, .archive, prepare: prepare)
        async let third = manager.dismantle(task.id, .close(deleteBranch: true), prepare: prepare)
        let (a, b, c) = try await (first, second, third)

        #expect(a.record?.isArchived == true && a == b && c.record == nil)
        #expect(prepared.withLock { $0 } <= 2)
        #expect(await manager.task(task.id) == nil)
        #expect(!(await scope.client(for: api).branchExists("feat/race")))
    }

    @Test func archivingTwiceKeepsTheFirstDate() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "once", branch: "feat/once", in: scope.declaration, repos: ["api"])
        let first = try await manager.archive(task.id)
        let again = try await manager.archive(task.id)
        #expect(first == again && first.cleanup == nil)
        // Closing a task that is already gone is not an error either.
        try await manager.close(task.id, deleteBranch: false)
        try await manager.close(task.id, deleteBranch: false)
    }

    /// `chflags uchg`: a folder nothing can rename, as a stuck mount or a permission problem would leave it.
    private func setImmutable(_ url: URL, _ on: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = [on ? "uchg" : "nouchg", url.path]
        try process.run()
        process.waitUntilExit()
    }

    @Test func aFailedStepIsPersistedAndTheNextRunResumes() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "half", branch: "feat/half", in: scope.declaration, repos: ["api", "web"])

        // The web sandbox cannot be moved: the run stops there, with api already gone.
        let web = task.repos[1].sandboxURL
        try setImmutable(web, true)
        await #expect(throws: TaskError.self) { try await manager.archive(task.id) }
        try setImmutable(web, false)

        let stored = try #require(await TaskRecordStore(home: scope.home).loadAll().records.first)
        #expect(stored.repos.map(\.state) == [.archived, .active])
        #expect(stored.cleanup?.mode == .archive && stored.cleanup?.error != nil && !stored.isArchived)
        #expect(!scope.exists(task.repos[0].sandboxURL) && scope.exists(web))

        let archived = try await manager.archive(task.id)
        #expect(archived.isArchived && archived.cleanup == nil && archived.repos.allSatisfy { $0.state == .archived })
        #expect(!scope.exists(task.rootURL))
    }

    @Test func aLockedWorktreeGoesToTheTrashAndOutOfGitsList() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "locked", branch: "feat/locked", in: scope.declaration, repos: ["api"])
        let base = await scope.client(for: api)
        _ = try await base.output(["worktree", "lock", task.repos[0].sandboxPath])

        let archived = try await manager.archive(task.id)
        #expect(archived.isArchived && !scope.exists(task.rootURL))
        let worktrees = try await base.output(["worktree", "list", "--porcelain"])
        #expect(!worktrees.contains(task.slug))

        await manager.emptyTrash()
        let trash = ScopeHome.trashURL(home: scope.home)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty)
    }

    @Test func whatTheThreadsLeftRunningIsStopped() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "server", branch: "feat/server", in: scope.declaration, repos: ["api"])
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/sh")
        server.arguments = ["-c", "trap '' TERM HUP; sleep 60 & wait"]
        server.currentDirectoryURL = task.repos[0].sandboxURL
        try server.run()
        try await Task.sleep(for: .milliseconds(200))

        let outcome = try await manager.dismantle(task.id, .archive)
        #expect(!outcome.stoppedProcesses.isEmpty && !outcome.notices.contains { if case .processesSurvived = $0 { true } else { false } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!server.isRunning)
    }

    @Test func uncommittedChangesAreSavedAndComeBackOnReopen() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "wip", branch: "feat/wip", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        try scope.write(sandbox, ".gitignore", "build/\n")
        try await scope.commit(in: sandbox, "ignore build")
        try scope.write(sandbox, "README.md", "edited\n")
        try scope.write(sandbox, "new.txt", "untracked\n")
        try FileManager.default.createDirectory(at: sandbox.appending(path: "build"), withIntermediateDirectories: true)
        try scope.write(sandbox, "build/out.bin", "cache\n")

        let outcome = try await manager.dismantle(task.id, .archive)
        let ref = try #require(outcome.record?.repos[0].salvageRef)
        #expect(outcome.notices.contains(.changesSaved(repo: "api", ref: ref, skipped: [])))
        #expect(!scope.exists(sandbox))
        let base = await scope.client(for: api)
        #expect(try await base.output(["show", "\(ref):new.txt"]) == "untracked")
        #expect(try await base.output(["show", "\(ref):README.md"]) == "edited")
        #expect(try await base.output(["ls-tree", "-r", "--name-only", ref]).contains("build/") == false)

        let reopened = try await manager.reopen(task.id)
        #expect(!reopened.isArchived && reopened.repos[0].state == .active && reopened.repos[0].salvageRef == nil)
        #expect(try String(contentsOf: sandbox.appending(path: "README.md"), encoding: .utf8) == "edited\n")
        #expect(try String(contentsOf: sandbox.appending(path: "new.txt"), encoding: .utf8) == "untracked\n")
        #expect(try await base.hasUncommittedChanges(at: sandbox))
    }

    @Test func restoringATaskWithAPullRequestKeepsItOpenAfterTheMerge() async throws {
        let scope = try await TestScope.make()
        _ = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "shipped", branch: "feat/shipped", in: scope.declaration, repos: ["api"])
        // Archived while open: the merge happens after, unseen, and the record still says `open` at restore.
        let link = LinkedPullRequest(number: 4, url: URL(string: "https://github.com/acme/api/pull/4")!, title: "x", state: "open")
        _ = try await manager.linkPullRequest(link, to: task.id)
        _ = try await manager.dismantle(task.id, .archive)

        let reopened = try await manager.reopen(task.id)
        #expect(reopened.keptOpenAfterMerge)
        #expect(MergedTaskArchive.decide(pullRequestState: "merged", threads: [], enabled: true,
                                         keptOpenAfterMerge: reopened.keptOpenAfterMerge) == .keep)
    }

    @Test func closingDeletesAnUnmergedBranchOnceItsTipIsSaved() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "gone", branch: "feat/gone", in: scope.declaration, repos: ["api"])
        try scope.write(task.repos[0].sandboxURL, "work.txt", "work\n")
        try await scope.commit(in: task.repos[0].sandboxURL, "work")
        let base = await scope.client(for: api)
        let tip = try await base.output(["rev-parse", "feat/gone"])

        let outcome = try await manager.dismantle(task.id, .close(deleteBranch: true))
        let saved = try #require(outcome.notices.first)
        guard case .branchSaved(let repo, let branch, let ref) = saved else { Issue.record("unexpected \(saved)"); return }
        #expect(repo == "api" && branch == "feat/gone")
        #expect(!(await base.branchExists("feat/gone")))
        #expect(try await base.output(["rev-parse", ref]) == tip)
        #expect(await manager.task(task.id) == nil)
    }

    @Test func aHugeUntrackedFileIsNotCopiedIntoTheRepository() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "dump", branch: "feat/dump", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        try scope.write(sandbox, "notes.txt", "keep\n")
        let dump = sandbox.appending(path: "dump.sql")
        FileManager.default.createFile(atPath: dump.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dump)
        try handle.truncate(atOffset: UInt64(TaskManager.salvageFileLimit + 1))   // sparse: big on paper only
        try handle.close()

        let outcome = try await manager.dismantle(task.id, .archive)
        let ref = try #require(outcome.record?.repos[0].salvageRef)
        #expect(outcome.notices.contains(.changesSaved(repo: "api", ref: ref, skipped: ["dump.sql"])))
        let files = try await scope.client(for: api).output(["ls-tree", "-r", "--name-only", ref])
        #expect(files.contains("notes.txt") && !files.contains("dump.sql"))
    }

    @Test func archivingKeepsTheRepliesAndTheReportForGood() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "study", branch: "feat/study", in: scope.declaration, repos: ["api"],
                                            deliverable: "docs/study.md")
        #expect(await TaskRecordStore(home: scope.home).loadAll().records.first?.deliverable == "docs/study.md")
        let sandbox = task.repos[0].sandboxURL
        try FileManager.default.createDirectory(at: sandbox.appending(path: "docs"), withIntermediateDirectories: true)
        try scope.write(sandbox, "docs/study.md", "# Study\n")
        try scope.write(sandbox, "REPORT.md", "report\n")
        let answer = TaskDeliverable.Reply(threadID: "th1", title: "Claude", driver: "claude", text: "## Findings",
                                           at: Date(timeIntervalSince1970: 1))

        _ = try await manager.dismantle(task.id, .archive, replies: [answer])
        let kept = try #require(TaskDeliverableStore.load(home: scope.home, taskID: task.id.rawValue))
        #expect(kept.replies == [answer])
        #expect(kept.files.map(\.name) == ["docs/study.md", "REPORT.md"])
        #expect(kept.files.map(\.text) == ["# Study\n", "report\n"])

        // A close afterwards finds no thread and no sandbox: what the archive kept stays, and outlives the record.
        try await manager.close(task.id, deleteBranch: false)
        #expect(await manager.task(task.id) == nil)
        #expect(TaskDeliverableStore.load(home: scope.home, taskID: task.id.rawValue) == kept)
        #expect(await TaskRecordStore(home: scope.home).loadAll().problems.isEmpty)
    }
}
