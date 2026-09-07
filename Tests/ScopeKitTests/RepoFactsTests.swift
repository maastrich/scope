import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// A throwaway repository under the temp directory, driven through a `GitClient` with an
/// isolated `HOME` (no user / system git config leaks into the assertions). Removed on deinit.
private final class GitFixtureRepo: Sendable {
    let root: URL
    let repo: URL
    let gitPath: String
    let client: GitClient

    private init(root: URL, repo: URL, gitPath: String, client: GitClient) {
        self.root = root
        self.repo = repo
        self.gitPath = gitPath
        self.client = client
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Environment that isolates every git invocation from the developer's machine.
    static func isolatedEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Scope Tests",
            "GIT_AUTHOR_EMAIL": "tests@scope.invalid",
            "GIT_COMMITTER_NAME": "Scope Tests",
            "GIT_COMMITTER_EMAIL": "tests@scope.invalid",
        ]
    }

    /// `git init -b main`, plus one commit of `README.md` unless `commit` is false.
    static func make(commit: Bool = true) async throws -> GitFixtureRepo {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scope-git-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let repo = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let gitPath = try await GitLocator().locate().path
        let client = GitClient(repository: repo, gitPath: gitPath, environment: isolatedEnvironment(home: home))
        let fixture = GitFixtureRepo(root: root, repo: repo, gitPath: gitPath, client: client)

        try await client.run(["init", "-q", "-b", "main"])
        if commit {
            try fixture.write("README.md", "# fixture\n")
            try await fixture.commit("initial")
        }
        return fixture
    }

    /// A client for another checkout (a worktree) sharing the same isolated environment.
    func client(for checkout: URL) -> GitClient {
        GitClient(
            repository: checkout, gitPath: gitPath,
            environment: Self.isolatedEnvironment(home: root.appending(path: "home"))
        )
    }

    func write(_ name: String, _ content: String) throws {
        try content.write(to: repo.appending(path: name), atomically: true, encoding: .utf8)
    }

    func commit(_ message: String) async throws {
        try await client.run(["add", "-A"])
        try await client.run(["commit", "-q", "-m", message])
    }

    /// Simulates a clone: `origin` remote, `refs/remotes/origin/main` at HEAD, `origin/HEAD` pointing at it,
    /// `main` tracking `origin/main`. No network involved.
    func addFakeOrigin(url: String = "git@github.com:acme/api.git") async throws {
        try await client.run(["remote", "add", "origin", url])
        try await client.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await client.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        try await client.run(["branch", "--set-upstream-to=origin/main", "main"])
    }
}

@Suite struct RepoFactsTests {
    @Test func originAndDefaultBranchFromOriginHead() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.addFakeOrigin()

        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.originURL == "git@github.com:acme/api.git")
        #expect(facts.remote?.fullName == "acme/api")
        #expect(facts.remote?.host == "github.com")
        #expect(facts.defaultBranch == "main")
        #expect(facts.currentBranch == "main")
        #expect(facts.status?.upstream == "origin/main")
        #expect(facts.ahead == 0)
        #expect(facts.behind == 0)
        #expect(!facts.isDirty)
        #expect(facts.worktrees.isEmpty)   // not requested
    }

    @Test func defaultBranchFromInitDefaultBranchConfig() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.client.run(["config", "init.defaultBranch", "develop"])

        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.originURL == nil)
        #expect(facts.remote == nil)
        #expect(facts.defaultBranch == "develop")
        #expect(facts.currentBranch == "main")
    }

    @Test func defaultBranchFromLocalMain() async throws {
        let fixture = try await GitFixtureRepo.make()
        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.defaultBranch == "main")
        #expect(facts.currentBranch == "main")
    }

    @Test func defaultBranchFromLocalMaster() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.client.run(["branch", "-m", "main", "master"])
        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.defaultBranch == "master")
        #expect(facts.currentBranch == "master")
    }

    @Test func currentBranchFollowsCheckout() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.client.run(["checkout", "-q", "-b", "scope/demo"])
        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.currentBranch == "scope/demo")
        #expect(facts.defaultBranch == "main")   // main still exists locally
    }

    @Test func detachedHeadHasNoCurrentBranch() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.client.run(["checkout", "-q", "--detach", "HEAD"])
        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.currentBranch == nil)
        #expect(facts.isDetached)
    }

    @Test func dirtyAndUntrackedAndAhead() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.addFakeOrigin()

        try fixture.write("README.md", "# changed\n")
        try await fixture.commit("second")             // main is now 1 ahead of the fake origin/main
        try fixture.write("README.md", "# dirty\n")     // unstaged change
        try fixture.write("new.txt", "hello\n")         // untracked

        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        let status = try #require(facts.status)
        #expect(facts.ahead == 1)
        #expect(facts.behind == 0)
        #expect(facts.isDirty)
        #expect(status.hasUntracked)
        #expect(status.entries.contains(GitStatus.Entry(xy: ".M", path: "README.md")))
        #expect(status.entries.contains(GitStatus.Entry(xy: "??", path: "new.txt")))
    }

    @Test func worktreesWhenRequested() async throws {
        let fixture = try await GitFixtureRepo.make()
        let sandbox = fixture.root.appending(path: "sandbox", directoryHint: .isDirectory)
        try await fixture.client.run(["worktree", "add", "-q", sandbox.path, "-b", "scope/demo"])

        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client, includeWorktrees: true)
        #expect(facts.worktrees.count == 2)
        #expect(facts.worktrees.map(\.branch) == ["main", "scope/demo"])
        #expect(facts.currentBranch == "main")

        // Facts of the worktree itself (its `.git` is a file, not a directory).
        let worktreeFacts = await RepoFacts.load(for: sandbox, using: fixture.client(for: sandbox))
        #expect(worktreeFacts.currentBranch == "scope/demo")
        #expect(worktreeFacts.defaultBranch == "main")
        #expect(!worktreeFacts.isDirty)
    }

    @Test func freshInitWithoutCommitsGivesNilsAndDoesNotThrow() async throws {
        let fixture = try await GitFixtureRepo.make(commit: false)
        let facts = await RepoFacts.load(for: fixture.repo, using: fixture.client)
        #expect(facts.originURL == nil)
        #expect(facts.remote == nil)
        #expect(facts.defaultBranch == nil)
        #expect(facts.currentBranch == nil)
        #expect(facts.status?.head == .initial)
        #expect(facts.worktrees.isEmpty)
    }

    @Test func notARepositoryStillReturnsFacts() async throws {
        let fixture = try await GitFixtureRepo.make()
        let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let facts = await RepoFacts.load(for: plain, using: fixture.client(for: plain))
        #expect(facts.originURL == nil)
        #expect(facts.defaultBranch == nil)
        #expect(facts.currentBranch == nil)
        #expect(facts.status == nil)
    }

    @Test func originFallsBackToGitConfigWhenGitCannotRun() async throws {
        let fixture = try await GitFixtureRepo.make()
        try await fixture.client.run(["remote", "add", "origin", "https://github.com/acme/api.git"])

        let broken = GitClient(repository: fixture.repo, gitPath: "/nonexistent/git")
        let facts = await RepoFacts.load(for: fixture.repo, using: broken)
        #expect(facts.originURL == "https://github.com/acme/api.git")
        #expect(facts.remote?.fullName == "acme/api")
        #expect(facts.status == nil)
    }

    @Test func gitClientReportsFailuresAsGitError() async throws {
        let fixture = try await GitFixtureRepo.make()
        await #expect(throws: GitError.self) {
            try await fixture.client.run(["rev-parse", "--verify", "--quiet", "refs/heads/nope"])
        }
        let tolerated = try await fixture.client.run(["rev-parse", "--verify", "--quiet", "refs/heads/nope"], allowFailure: true)
        #expect(!tolerated.succeeded)
    }
}
