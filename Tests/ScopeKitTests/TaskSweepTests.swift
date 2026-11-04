import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// Taking out of a task what it gained — a repository, a worktree, a pull request, the issue, a milestone — one at a
/// time, or all at once with a sweep that brings it back to a fresh state and can be undone.
@Suite(.serialized) struct TaskSweepTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    private static func link(_ number: Int, repo: String = "api", branch: String = "feat/x", state: String? = "open") -> LinkedPullRequest {
        var link = LinkedPullRequest(number: number, url: URL(string: "https://github.com/acme/\(repo)/pull/\(number)")!, title: "PR \(number)",
                                     repo: repo, headRefName: branch)
        link.state = state
        return link
    }

    /// `api` and `web` from the start, `docs` added later, a second worktree of `api` on `fix/login`.
    private static func multiRepoRecord() -> TaskRecord {
        var api = TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api", branch: "feat/x")
        api.worktrees = [TaskWorktree(branch: "fix/login", sandboxPath: "/t/api@login")]
        let web = TaskRepo(repoRelativePath: "web", sandboxPath: "/t/web", branch: "feat/x")
        let docs = TaskRepo(repoRelativePath: "docs", sandboxPath: "/t/docs", branch: "feat/x", addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "X", slug: "x", branch: "feat/x",
                          root: "/t", repos: [api, web, docs], createdAt: Date(timeIntervalSince1970: 1_800_000_000), pullRequests: [link(1), link(2, repo: "web"), link(3, branch: "fix/login")])
    }

    // MARK: The plan

    @Test func aSweepRemovesWhatWasAddedAndResetsTheRest() {
        let record = Self.multiRepoRecord()
        let facts = ["api": SandboxFacts(unpushedCommits: 2, changedFiles: ["a.swift"]),
                     "api@fix/login": SandboxFacts(unpushedCommits: 1),
                     "docs": SandboxFacts(changedFiles: ["guide.md", "new.md"])]
        let plan = TaskSweepPlan.make(record, facts: facts)
        #expect(plan.blocked == nil && !plan.isEmpty)
        // The repositories the task was created with stay and are reset; the added one and the second worktree go.
        #expect(plan.reset.map(\.key) == ["api", "web"])
        #expect(Set(plan.removed.map(\.key)) == ["api@fix/login", "docs"])
        #expect(plan.removedRepos == ["docs"])
        #expect(plan.pullRequests.map(\.number) == [1, 3, 2])
        // What is at stake, as the confirmation counts it.
        #expect(plan.unpushedCommits == 3 && plan.changedFiles == 3)
        #expect(plan.sandboxes.first { $0.key == "api" }?.losesWork == true)
        #expect(plan.sandboxes.first { $0.key == "web" }?.losesWork == false)
        let lines = plan.lines(scopeName: "acme")
        #expect(lines.contains { $0.contains("#1") && $0.contains("stays open on GitHub") })
        #expect(lines.contains { $0.contains("Repository docs") })
        #expect(lines.contains { $0.contains("api · fix/login") && $0.contains("1 unpushed commit") })
        #expect(lines.contains { $0.hasPrefix("Worktree api:") && $0.contains("2 unpushed commits, 1 modified file") })
        #expect(!lines.contains { $0.contains("Remote branches") })
    }

    @Test func theOptionsChangeWhatTheSweepDoes() {
        let record = Self.multiRepoRecord()
        let keep = TaskSweepPlan.make(record, options: TaskSweepOptions(resetBranches: false))
        #expect(keep.reset.isEmpty)
        #expect(keep.sandboxes.filter { $0.action == .keep }.map(\.key) == ["api", "web"])
        let github = TaskSweepPlan.make(record, options: TaskSweepOptions(closePullRequests: true, deleteRemoteBranches: true))
        let lines = github.lines(scopeName: "acme")
        #expect(lines.contains { $0.contains("#1") && $0.contains("closed on GitHub") })
        #expect(lines.contains { $0.contains("Remote branches deleted on origin: feat/x, fix/login") })
        // The defaults never touch GitHub.
        #expect(!TaskSweepOptions().touchesGitHub && TaskSweepOptions().resetBranches)
    }

    @Test func aTaskKeepsOneRepositoryAndASweepWaitsForATry() {
        var record = Self.multiRepoRecord()
        // The originals removed one by one: the first repository left stays.
        record.repos.removeAll { $0.addedAt == nil }
        record.repos.append(TaskRepo(repoRelativePath: "ios", sandboxPath: "/t/ios", branch: "feat/x", addedAt: .now))
        let plan = TaskSweepPlan.make(record)
        #expect(plan.removedRepos == ["ios"] && plan.reset.map(\.key) == ["docs"])

        var trying = Self.multiRepoRecord()
        trying.trying = [TrySession(repoRelativePath: "api", previousHead: "abc", previousBranch: nil, stashSHA: nil, head: "def", since: .now)]
        #expect(TaskSweepPlan.make(trying).blocked?.contains("trying") == true)
        var archived = Self.multiRepoRecord()
        archived.archivedAt = .now
        #expect(TaskSweepPlan.make(archived).blocked?.contains("archived") == true)
        // A fresh task with nothing gained is nothing to sweep, branch reset left aside.
        let fresh = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "F", slug: "f", branch: "feat/f",
                               root: "/t", repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api", branch: "feat/f")])
        #expect(TaskSweepPlan.make(fresh, options: TaskSweepOptions(resetBranches: false)).isEmpty)
    }

    @Test func applyThenRevertGivesTheRecordBack() {
        var record = Self.multiRepoRecord()
        // Kept open past a merge: the undo must not hand the next refresh a task to archive.
        record.keptOpenAfterMerge = true
        let plan = TaskSweepPlan.make(record)
        let undo = TaskSweepUndo(at: .now, options: plan.options, sandboxes: [],
                                 removedRepos: record.repos.filter { $0.repoRelativePath == "docs" },
                                 removedWorktrees: ["api": record.repos[0].worktrees],
                                 pullRequests: record.pullRequests, ignoredPullRequests: record.ignoredPullRequests)
        let swept = TaskSweep.apply(plan, to: record, undo: undo)
        #expect(swept.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(swept.repos[0].worktrees.isEmpty)
        #expect(swept.pullRequests.isEmpty)
        #expect(Set(swept.ignoredPullRequests) == Set(record.pullRequests.map(\.url)))
        #expect(swept.lastSweep == undo)
        let back = TaskSweep.revert(undo, on: swept)
        #expect(back.repos.map(\.repoRelativePath) == ["api", "web", "docs"])
        #expect(back.repos[0].worktrees == record.repos[0].worktrees)
        #expect(back.pullRequests == record.pullRequests)
        #expect(back.ignoredPullRequests.isEmpty && back.lastSweep == nil)
        #expect(back.keptOpenAfterMerge)
        #expect(back == record)
    }

    // MARK: One at a time, on the record

    @Test func aForgottenPullRequestNeverComesBackFromADiscovery() {
        var record = Self.multiRepoRecord()
        let forgotten = record.pullRequests[0]
        record.forgetPullRequest(forgotten.url)
        #expect(!record.pullRequests.contains(forgotten))
        #expect(record.ignores(forgotten.url))
        // The next refresh finds it again on the branch: it stays out, the others come through.
        let found = record.discovered([forgotten, Self.link(9)])
        #expect(found.map(\.number) == [9])
        // Forgetting twice keeps one entry.
        record.forgetPullRequest(forgotten.url)
        #expect(record.ignoredPullRequests.count == 1)
    }

    @Test func aRepositoryLeavesWithItsPullRequestsButNeverTheLastOne() throws {
        let record = Self.multiRepoRecord()
        let without = try TaskSweep.removingRepo("web", from: record)
        #expect(without.repos.map(\.repoRelativePath) == ["api", "docs"])
        #expect(without.pullRequests.map(\.number) == [1, 3])
        #expect(throws: TaskError.self) { try TaskSweep.removingRepo("ios", from: record) }
        let single = try TaskSweep.removingRepo("docs", from: try TaskSweep.removingRepo("web", from: record))
        #expect(throws: TaskError.self) { try TaskSweep.removingRepo("api", from: single) }
        let mono = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "M", slug: "m", branch: "feat/m",
                              root: "/t", repos: [TaskRepo(repoRelativePath: ".", sandboxPath: "/t", branch: "feat/m")])
        #expect(throws: TaskError.self) { try TaskSweep.removingRepo(".", from: mono) }
        var trying = record
        trying.trying = [TrySession(repoRelativePath: "web", previousHead: "a", previousBranch: nil, stashSHA: nil, head: "b", since: .now)]
        #expect(throws: TaskError.self) { try TaskSweep.removingRepo("web", from: trying) }
    }

    @Test func aMilestoneGoesByIdNumberOrTitle() throws {
        var record = Self.multiRepoRecord()
        record.mission = Mission(milestones: [Milestone(id: "aaaa0001", title: "Schema"), Milestone(id: "aaaa0002", title: "API"),
                                              Milestone(id: "aaaa0003", title: "UI")])
        #expect(try TaskSweep.removingMilestone("aaaa0002", from: record).mission?.milestones.map(\.title) == ["Schema", "UI"])
        #expect(try TaskSweep.removingMilestone("3", from: record).mission?.milestones.map(\.title) == ["Schema", "API"])
        #expect(try TaskSweep.removingMilestone("schema", from: record).mission?.milestones.map(\.title) == ["API", "UI"])
        #expect(throws: TaskError.self) { try TaskSweep.removingMilestone("9", from: record) }
        #expect(throws: TaskError.self) { try TaskSweep.removingMilestone("1", from: Self.multiRepoRecord()) }
    }

    @Test func aSweepNeverDeletesTheDefaultBranchOnTheRemote() {
        // A task branch tracks origin/main: the upstream's name is never what gets deleted, and main never is.
        #expect(TaskManager.mayDeleteRemote(branch: "feat/x", defaultBranch: "main"))
        #expect(!TaskManager.mayDeleteRemote(branch: "main", defaultBranch: "main"))
        #expect(!TaskManager.mayDeleteRemote(branch: "trunk", defaultBranch: "trunk"))
        #expect(!TaskManager.mayDeleteRemote(branch: "master", defaultBranch: nil))
        #expect(!TaskManager.mayDeleteRemote(branch: "", defaultBranch: "main"))
    }

    @Test func gitStatusPathsAreReadWithRenames() {
        let output = " M src/a.swift\0?? new file.txt\0R  moved.txt\0old.txt\0D  gone.txt\0"
        #expect(SandboxFacts.changedFiles(porcelainZ: output) == ["src/a.swift", "new file.txt", "moved.txt", "gone.txt"])
    }

    @Test func theNewFieldsStayOutOfRecordsThatNeverUsedThem() throws {
        let record = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/r", scopeSlug: "acme", name: "T", slug: "t",
                                branch: "feat/t", root: "/t", repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/t/api", branch: "feat/t")],
                                createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(!text.contains("ignoredPullRequests") && !text.contains("lastSweep") && !text.contains("addedAt"))
        #expect(try decoder.decode(TaskRecord.self, from: Data(text.utf8)) == record)
        var swept = Self.multiRepoRecord()
        swept.forgetPullRequest(swept.pullRequests[0].url)
        swept.lastSweep = TaskSweepUndo(at: Date(timeIntervalSince1970: 1_800_000_000), options: .init(), sandboxes: [
            .init(key: "api", repo: "api", branch: "feat/x", path: "/t/api", isSecondary: false, action: .reset, head: "abc",
                  upstream: "origin/feat/x", ref: "refs/scope/salvage/x/sweep-api-1")
        ], removedRepos: [], removedWorktrees: [:], pullRequests: [], ignoredPullRequests: [])
        #expect(try decoder.decode(TaskRecord.self, from: try encoder.encode(swept)) == swept)
    }

    // MARK: The manager, on real repositories

    @Test func linkingDropsIgnoredPullRequestsUnlessAskedExplicitly() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Login", branch: "feat/login", in: scope.declaration, repos: ["api"])
        let pr = Self.link(4, branch: "feat/login")
        try await manager.linkPullRequest(pr, to: task.id)
        let forgotten = try await manager.forgetPullRequest(task.id, url: pr.url)
        #expect(forgotten.pullRequests.isEmpty && forgotten.ignores(pr.url))
        // The refresh finds it on the branch again: nothing is bound.
        let rediscovered = try await manager.linkPullRequests([pr, Self.link(5, branch: "feat/login")], to: task.id)
        #expect(rediscovered.pullRequests.map(\.number) == [5])
        // Created or picked by the user: back in, and off the ignore list.
        let explicit = try await manager.linkPullRequest(pr, to: task.id, explicit: true)
        #expect(explicit.pullRequests.map(\.number) == [4, 5] && !explicit.ignores(pr.url))
        // The issue goes the same way, and the record says so once reloaded.
        let unlinked = try await manager.unlinkIssue(task.id)
        #expect(unlinked.issue == nil)
        #expect(await TaskRecordStore(home: scope.home).loadAll().records == [unlinked])
    }

    @Test func removingARepositorySavesItsWorkAndKeepsItsBranch() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let web = try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let created = try await manager.create(name: "Both", branch: "feat/both", in: scope.declaration, repos: ["api", "web"])
        _ = try await manager.addBranch(created.id, branch: "fix/web", repo: "web")
        let task = try #require(await manager.task(created.id))
        let webSandbox = try #require(task.repo(at: "web"))
        try scope.write(webSandbox.sandboxURL, "wip.txt", "unsaved\n")
        try await manager.linkPullRequest(Self.link(7, repo: "web", branch: "feat/both"), to: task.id)

        let (record, notices) = try await manager.removeRepo(task.id, repo: "web", contextFiles: ["CLAUDE.md"])
        #expect(record.repos.map(\.repoRelativePath) == ["api"])
        #expect(record.pullRequests.isEmpty)
        #expect(!scope.exists(webSandbox.sandboxURL) && !scope.exists(webSandbox.worktrees[0].sandboxURL))
        let webClient = await scope.client(for: web)
        #expect(await webClient.branchExists("feat/both"))
        #expect(await webClient.branchExists("fix/web"))
        let saved = notices.compactMap { notice -> String? in
            if case .changesSaved(let repo, let ref, _) = notice, repo == "web" { return ref }
            return nil
        }
        let ref = try #require(saved.first)
        #expect(try await webClient.output(["show", "\(ref):wip.txt"]) == "unsaved")
        // The user's checkout did not move, and the task now starts its threads in the one sandbox left.
        #expect(try await webClient.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "main")
        #expect(record.threadCwd.path == record.repos[0].sandboxURL.path)
        #expect(scope.exists(record.repos[0].sandboxURL.appending(path: "AGENTS.md")))
        #expect(!scope.exists(record.rootURL.appending(path: "AGENTS.md")))
        // The last repository is not one to remove.
        await #expect(throws: TaskError.self) { try await manager.removeRepo(task.id, repo: "api") }
        _ = api
    }

    @Test func aRepositoryAddedLaterIsMarkedSo() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "One", branch: "feat/one", in: scope.declaration, repos: ["api"])
        #expect(task.repos[0].addedAt == nil)
        let record = try await manager.addRepo(task.id, repo: "web")
        #expect(record.repo(at: "web")?.addedAt != nil)
        #expect(TaskSweepPlan.make(record).removedRepos == ["web"])
    }

    /// The whole thing on a task of two repositories, one added later, with a second worktree, unpushed commits, an
    /// uncommitted change and a pull request: swept, then undone.
    @Test func aSweepResetsRemovesForgetsAndItsUndoPutsEverythingBack() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let web = try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let created = try await manager.create(name: "Sweep", branch: "feat/sweep", in: scope.declaration, repos: ["api"])
        _ = try await manager.addRepo(created.id, repo: "web")
        _ = try await manager.addBranch(created.id, branch: "docs/sweep", repo: "api")
        let task = try #require(await manager.task(created.id))
        let primary = try #require(task.repo(at: "api"))
        let secondary = try #require(primary.worktrees.first)
        let webSandbox = try #require(task.repo(at: "web"))
        // Two unpushed commits and an uncommitted file on the task branch; a commit on the second worktree.
        try scope.write(primary.sandboxURL, "feature.txt", "one\n")
        try await scope.commit(in: primary.sandboxURL, "one")
        try scope.write(primary.sandboxURL, "feature.txt", "two\n")
        try await scope.commit(in: primary.sandboxURL, "two")
        try scope.write(primary.sandboxURL, "draft.txt", "unsaved\n")
        try scope.write(secondary.sandboxURL, "docs.md", "docs\n")
        try await scope.commit(in: secondary.sandboxURL, "docs")
        let apiSandbox = await scope.client(for: primary.sandboxURL)
        let tip = try await apiSandbox.output(["rev-parse", "HEAD"])
        let pr = Self.link(12, branch: "feat/sweep")
        try await manager.linkPullRequest(pr, to: task.id)

        let plan = try await manager.planSweep(task.id)
        #expect(plan.sandboxes.first { $0.key == "api" }?.unpushedCommits == 2)
        #expect(plan.sandboxes.first { $0.key == "api" }?.changedFiles == ["draft.txt"])
        #expect(plan.sandboxes.first { $0.key == "api@docs/sweep" }?.unpushedCommits == 1)

        let outcome = try await manager.sweepTask(task.id, checkpoint: nil)
        let swept = outcome.record
        // Fresh: the branch on origin/main, nothing local, the second worktree and the added repository gone.
        let main = try await apiSandbox.output(["rev-parse", "origin/main"])
        #expect(try await apiSandbox.output(["rev-parse", "HEAD"]) == main)
        #expect(try await apiSandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/sweep")
        #expect(!scope.exists(primary.sandboxURL.appending(path: "draft.txt")))
        #expect(!scope.exists(secondary.sandboxURL) && !scope.exists(webSandbox.sandboxURL))
        #expect(swept.repos.map(\.repoRelativePath) == ["api"] && swept.repos[0].worktrees.isEmpty)
        #expect(swept.pullRequests.isEmpty && swept.ignores(pr.url))
        // Branches are kept, the user's checkouts never moved.
        let apiBase = await scope.client(for: api)
        let webBase = await scope.client(for: web)
        #expect(await apiBase.branchExists("docs/sweep"))
        #expect(await webBase.branchExists("feat/sweep"))
        #expect(try await apiBase.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "main")
        // Every sandbox touched was kept under refs/scope/salvage/, the dirty one with its working tree.
        let undo = try #require(swept.lastSweep)
        let kept = try #require(undo.sandboxes.first { $0.key == "api" })
        #expect(kept.head == tip)
        #expect(try await apiBase.output(["show", "\(kept.ref):draft.txt"]) == "unsaved")
        #expect(undo.sandboxes.count == 3)
        // The sweep's refs are the records': the garbage collection keeps them.
        let reloaded = await TaskRecordStore(home: scope.home).loadAll().records
        #expect(reloaded.first?.lastSweep == swept.lastSweep)
        #expect(reloaded.first?.repos == swept.repos)
        #expect(reloaded == [swept])
        // A pull request the refresh finds again stays forgotten.
        #expect(try await manager.linkPullRequests([pr], to: task.id).pullRequests.isEmpty)

        let (back, _) = try await manager.undoSweep(task.id)
        #expect(try await apiSandbox.output(["rev-parse", "HEAD"]) == tip)
        #expect(try String(contentsOf: primary.sandboxURL.appending(path: "draft.txt"), encoding: .utf8) == "unsaved\n")
        #expect(try String(contentsOf: primary.sandboxURL.appending(path: "feature.txt"), encoding: .utf8) == "two\n")
        #expect(scope.exists(secondary.sandboxURL.appending(path: "docs.md")))
        #expect(scope.exists(webSandbox.sandboxURL.appending(path: "README.md")))
        #expect(back.repos.map(\.repoRelativePath) == ["api", "web"])
        #expect(back.repos[0].worktrees.map(\.branch) == ["docs/sweep"])
        #expect(back.pullRequests.map(\.number) == [12] && !back.ignores(pr.url))
        #expect(back.lastSweep == nil)
        await #expect(throws: TaskError.self) { try await manager.undoSweep(task.id) }
    }

    @Test func deletingRemoteBranchesTakesTheTaskBranchNeverMain() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Pushed", branch: "feat/pushed", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        try scope.write(sandbox, "work.txt", "w\n")
        try await scope.commit(in: sandbox, "work")
        let client = await scope.client(for: sandbox)
        try await client.run(["-C", sandbox.path, "push", "-q", "origin", "feat/pushed"])
        let base = await scope.client(for: api)
        try await base.fetch(remote: "origin")
        #expect(await base.refExists("origin/feat/pushed"))

        let outcome = try await manager.sweepTask(task.id, options: TaskSweepOptions(deleteRemoteBranches: true))
        try await base.fetch(remote: "origin")
        _ = try? await base.run(["fetch", "--prune", "origin"])
        #expect(!(await base.refExists("origin/feat/pushed")))
        #expect(await base.refExists("origin/main"))
        #expect(outcome.notes.contains { $0.contains("deleted feat/pushed on origin") })
    }

    @Test func aSweepWithoutTheResetLeavesTheBranchesAlone() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Keep", branch: "feat/keep", in: scope.declaration, repos: ["api"])
        let sandbox = task.repos[0].sandboxURL
        try scope.write(sandbox, "work.txt", "kept\n")
        try await scope.commit(in: sandbox, "work")
        try await manager.linkPullRequest(Self.link(3, branch: "feat/keep"), to: task.id)
        let client = await scope.client(for: sandbox)
        let tip = try await client.output(["rev-parse", "HEAD"])

        let outcome = try await manager.sweepTask(task.id, options: TaskSweepOptions(resetBranches: false))
        #expect(try await client.output(["rev-parse", "HEAD"]) == tip)
        #expect(outcome.record.pullRequests.isEmpty)
        #expect(outcome.record.lastSweep?.sandboxes.isEmpty == true)
    }
}
