import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// `TaskManager.createForPullRequest` against a bare origin that holds the PR head (`gh` is never called:
/// the `PullRequest` value is injected).
@Suite(.serialized) struct PullRequestTaskTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    /// Pushes a `feature/x` branch with one extra commit to the bare origin of `repo`, then drops the local branch.
    private func publishHead(_ scope: TestScope, repo: URL, branch: String, file: String) async throws -> String {
        let client = await scope.client(for: repo)
        try await client.run(["checkout", "-q", "-b", branch])
        try scope.write(repo, file, "hello\n")
        try await scope.commit(in: repo, "pr commit")
        let sha = try await client.output(["rev-parse", "HEAD"])
        try await client.run(["push", "-q", "origin", branch])
        try await client.run(["checkout", "-q", "main"])
        try await client.run(["branch", "-D", branch])
        return sha
    }

    /// The path a prompt naming a pull request takes: `create(startPoint: .pullRequest)`, not
    /// `createForPullRequest` — same result, plus the prompt.
    @Test func createFromAPromptOnAPullRequestChecksItsHeadOutAndBindsTheRecord() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let sha = try await publishHead(scope, repo: api, branch: "feat/lcm-agent-tab", file: "agent.txt")
        let manager = makeManager(scope)
        let pr = PullRequest(number: 6613, title: "Agent tab", author: "ada", headRefName: "feat/lcm-agent-tab",
                             baseRefName: "main", url: URL(string: "https://github.com/acme/api/pull/6613")!)

        let task = try await manager.create(
            name: TaskManager.taskName(forPullRequest: pr), branch: "chore/rebase-pr-6613",
            slug: TaskManager.taskSlug(forPullRequest: pr), initialPrompt: "rebase la pr .../pull/6613",
            in: scope.declaration, repos: ["api"], startPoint: .pullRequest(pr),
            pullRequest: LinkedPullRequest(pr), scopeRepos: ["api", "web"]
        )
        // The branch the caller passed is ignored: the pull request already has one.
        #expect(task.branch == "feat/lcm-agent-tab")
        #expect(task.name == "#6613 Agent tab")
        #expect(task.slug == "pr-6613-agent-tab")
        #expect(task.prompt == "rebase la pr .../pull/6613")
        #expect(task.pullRequest?.number == 6613)
        #expect(task.pullRequest?.isCrossRepository == false)
        #expect(task.repos.map(\.repoRelativePath) == ["api"])
        let sandbox = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feat/lcm-agent-tab")
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == sha)
        #expect(scope.exists(task.repos[0].sandboxURL.appending(path: "agent.txt")))
    }

    @Test func aTaskOnAPullRequestSandboxesOneRepositoryOnly() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        _ = try await publishHead(scope, repo: api, branch: "feature/y", file: "y.txt")
        let manager = makeManager(scope)
        let pr = PullRequest(number: 7, title: "Y", author: "ada", headRefName: "feature/y",
                             baseRefName: "main", url: URL(string: "https://github.com/acme/api/pull/7")!)

        await #expect(throws: TaskError.self) {
            try await manager.create(
                name: "#7 Y", branch: "feature/y", in: scope.declaration, repos: ["api", "web"],
                startPoint: .pullRequest(pr), pullRequest: LinkedPullRequest(pr)
            )
        }
    }

    @Test func createsASandboxOnTheHeadOfASameRepoPullRequest() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let sha = try await publishHead(scope, repo: api, branch: "feature/x", file: "feature.txt")
        let manager = makeManager(scope)
        let pr = PullRequest(number: 42, title: "Fix refresh token!", author: "alice", headRefName: "feature/x",
                             baseRefName: "main", url: URL(string: "https://github.com/acme/api/pull/42")!)

        let task = try await manager.createForPullRequest(pr, in: scope.declaration, repo: "api", scopeRepos: ["api", "web"])
        #expect(task.name == "#42 Fix refresh token!")
        #expect(task.slug == "pr-42-fix-refresh-token")
        #expect(task.branch == "feature/x")
        #expect(task.repos.map(\.repoRelativePath) == ["api"])
        #expect(task.pullRequest == LinkedPullRequest(number: 42, url: pr.url, title: "Fix refresh token!", headOwner: nil, isCrossRepository: false))

        let sandbox = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/x")
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == sha)
        #expect(scope.exists(task.repos[0].sandboxURL.appending(path: "feature.txt")))
        // The branch tracks origin/feature/x, so Push in the Delta panel updates the PR.
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) == "origin/feature/x")

        // Lookups.
        #expect(await manager.task(forPullRequest: 42, in: scope.declaration.id) == task)
        #expect(await manager.task(forPullRequest: 43, in: scope.declaration.id) == nil)

        // Persisted with the link and reloadable by a fresh manager.
        let fresh = makeManager(scope)
        #expect(await fresh.loadAll().isEmpty)
        #expect(await fresh.task(forPullRequest: 42, in: scope.declaration.id)?.pullRequest?.number == 42)
    }

    @Test func createsALocalPrBranchForACrossRepositoryPullRequest() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        // A fork's head is only reachable as `pull/<n>/head` on origin: simulate that ref on the bare remote.
        let sha = try await publishHead(scope, repo: api, branch: "carol-fix", file: "fork.txt")
        let bare = scope.root.appending(path: "remotes/api.git", directoryHint: .isDirectory)
        let bareClient = await scope.client(for: bare)
        try await bareClient.run(["update-ref", "refs/pull/7/head", sha])
        try await bareClient.run(["branch", "-D", "carol-fix"])
        let manager = makeManager(scope)
        let pr = PullRequest(number: 7, title: "From a fork", author: "carol", headRefName: "carol-fix", baseRefName: "main",
                             url: URL(string: "https://github.com/acme/api/pull/7")!, isCrossRepository: true, headOwner: "carol")

        let task = try await manager.createForPullRequest(pr, in: scope.declaration, repo: "api")
        #expect(task.branch == "pr/7" && task.slug == "pr-7-from-a-fork")
        #expect(task.pullRequest?.isCrossRepository == true && task.pullRequest?.headOwner == "carol")
        let sandbox = await scope.client(for: task.repos[0].sandboxURL)
        #expect(try await sandbox.output(["rev-parse", "--abbrev-ref", "HEAD"]) == "pr/7")
        #expect(try await sandbox.output(["rev-parse", "HEAD"]) == sha)
        #expect(scope.exists(task.repos[0].sandboxURL.appending(path: "fork.txt")))
    }

    @Test func missingHeadFailsAndRollsBack() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let pr = PullRequest(number: 9, title: "Ghost", author: "x", headRefName: "nope", baseRefName: "main",
                             url: URL(string: "https://github.com/acme/api/pull/9")!)
        await #expect(throws: TaskError.self) {
            try await manager.createForPullRequest(pr, in: scope.declaration, repo: "api")
        }
        #expect(await manager.tasks(in: scope.declaration.id).isEmpty)
        #expect(!scope.exists(scope.home.appending(path: "sandboxes/acme/pr-9-ghost")))
    }

    @Test func linksAPullRequestToAnExistingTaskAndRecordsStayBackwardsCompatible() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        #expect(task.pullRequest == nil)
        let link = LinkedPullRequest(number: 3, url: URL(string: "https://github.com/acme/api/pull/3")!, title: "Auth")
        let linked = try await manager.linkPullRequest(link, to: task.id)
        #expect(linked.pullRequest == link)
        #expect(await manager.task(forPullRequest: 3, in: scope.declaration.id)?.id == task.id)

        // A record written without the field decodes with `pullRequest == nil`.
        let file = TaskRecordStore(home: scope.home).url(for: task.id)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        #expect(json["pullRequest"] != nil)
        json["pullRequest"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let fresh = makeManager(scope)
        #expect(await fresh.loadAll().isEmpty)
        #expect(await fresh.task(task.id)?.pullRequest == nil)
    }
}
