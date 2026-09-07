import Foundation
import Testing
@testable import ScopeCore

/// A throw-away folder populated with real `git init` repos. Removed on deinit.
private final class DiscoveryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "scope-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates the folder and runs `git init -q -b main` in it, with one empty commit so worktrees can be added.
    @discardableResult
    func makeRepo(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: url)
        return url
    }

    /// Adds a worktree of `repo` at `relativePath` on a new branch; its `.git` is a file.
    @discardableResult
    func makeWorktree(of repo: URL, at relativePath: String, branch: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try git(["worktree", "add", "-q", "-b", branch, url.path], in: repo)
        return url
    }

    @discardableResult
    func makeFolder(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Scope Tests", "-c", "user.email=tests@scope.invalid"] + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(arguments, process.terminationStatus)
        }
    }

    enum FixtureError: Error { case gitFailed([String], Int32) }
}

@Suite struct RepoDiscoveryTests {
    /// The multi-repo layout used by most tests:
    /// `api` (clone), `api-wt` (worktree → `.git` file), `.hidden/repo`, `deep/nested`, `link -> api`, `plain/`.
    private func makeMultiRepoScope() throws -> DiscoveryFixture {
        let fixture = try DiscoveryFixture()
        let api = try fixture.makeRepo("api")
        try fixture.makeWorktree(of: api, at: "api-wt", branch: "scope/demo")
        try fixture.makeRepo(".hidden/repo")
        try fixture.makeRepo("deep/nested")
        try fixture.makeFolder("plain")
        try "hello".write(to: fixture.root.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "link"), withDestinationURL: api)
        return fixture
    }

    @Test func depthOneFindsCloneAndWorktreeOnly() throws {
        let fixture = try makeMultiRepoScope()
        let repos = RepoDiscovery(maxDepth: 1).scan(fixture.root)

        #expect(repos.map(\.relativePath) == ["api", "api-wt"])
        #expect(repos.map(\.depth) == [1, 1])
        #expect(repos.allSatisfy { !$0.isSecondary })
        #expect(repos[0].kind == .directory)
        guard case .file(let gitdir) = repos[1].kind else {
            Issue.record("worktree should be detected through its .git file")
            return
        }
        #expect(gitdir.hasSuffix("/.git/worktrees/api-wt"))
        #expect(repos[1].gitDirectory.lastPathComponent == "api-wt")
        #expect(FileManager.default.fileExists(atPath: repos[1].gitDirectory.appending(path: "commondir").path))
    }

    @Test func depthTwoFindsNestedRepoButStillSkipsHidden() throws {
        let fixture = try makeMultiRepoScope()
        let repos = RepoDiscovery(maxDepth: 2).scan(fixture.root)

        #expect(repos.map(\.relativePath) == ["api", "api-wt", "deep/nested"])
        #expect(repos.first { $0.relativePath == "deep/nested" }?.depth == 2)
        #expect(!repos.contains { $0.relativePath.contains(".hidden") })
    }

    @Test func depthZeroOnlyLooksAtTheRoot() throws {
        let fixture = try makeMultiRepoScope()
        #expect(RepoDiscovery(maxDepth: 0).scan(fixture.root).isEmpty)
    }

    @Test func symlinksAreSkippedUnlessFollowedAndThenDeduplicated() throws {
        let fixture = try makeMultiRepoScope()

        let skipped = RepoDiscovery(maxDepth: 1).scan(fixture.root)
        #expect(!skipped.contains { $0.relativePath == "link" })

        let followed = RepoDiscovery(maxDepth: 1, followSymlinks: true).scan(fixture.root)
        #expect(followed.map(\.relativePath) == ["api", "api-wt"], "link -> api resolves to the same folder as api")
    }

    @Test func plainFoldersAndFilesAreNotRepos() throws {
        let fixture = try DiscoveryFixture()
        try fixture.makeFolder("docs")
        try "x".write(to: fixture.root.appending(path: "notes.md"), atomically: true, encoding: .utf8)

        #expect(RepoDiscovery(maxDepth: 3).scan(fixture.root).isEmpty)
        #expect(RepoDiscovery.gitKind(at: fixture.root.appending(path: "docs")) == nil)
    }

    @Test func repoScopeRootIsReportedAtDepthZeroWithEmptyRelativePath() throws {
        let fixture = try DiscoveryFixture()
        try fixture.makeRepo("")
        let repos = RepoDiscovery(maxDepth: 1).scan(fixture.root)

        #expect(repos.count == 1)
        #expect(repos[0].depth == 0)
        #expect(repos[0].relativePath == "")
        #expect(repos[0].isScopeRoot)
        #expect(!repos[0].isSecondary)
        #expect(repos[0].url == fixture.root)
        #expect(repos[0].gitDirectory == fixture.root.appending(path: ".git"))
    }

    @Test func repoScopeRecordsNestedCheckoutsAsSecondary() throws {
        let fixture = try DiscoveryFixture()
        try fixture.makeRepo("")
        try fixture.makeRepo("sub")
        try fixture.makeRepo("vendor/lib")

        let shallow = RepoDiscovery(maxDepth: 1).scan(fixture.root)
        #expect(shallow.map(\.relativePath) == ["", "sub"])
        #expect(shallow.map(\.isSecondary) == [false, true])

        let deeper = RepoDiscovery(maxDepth: 2).scan(fixture.root)
        #expect(deeper.map(\.relativePath) == ["", "sub", "vendor/lib"])
        #expect(deeper.map(\.isSecondary) == [false, true, true])
        #expect(deeper.map(\.depth) == [0, 1, 2])
    }

    @Test func reposBelowTheRootAreLeavesUnlessDescendIntoReposIsSet() throws {
        let fixture = try DiscoveryFixture()
        try fixture.makeRepo("api")
        try fixture.makeRepo("api/vendor/lib")

        let leaves = RepoDiscovery(maxDepth: 3).scan(fixture.root)
        #expect(leaves.map(\.relativePath) == ["api"])

        let descended = RepoDiscovery(maxDepth: 3, descendIntoRepos: true).scan(fixture.root)
        #expect(descended.map(\.relativePath) == ["api", "api/vendor/lib"])
        #expect(descended.map(\.isSecondary) == [false, true])
    }

    @Test func gitKindReadsTheGitdirLineOfAGitFile() throws {
        let fixture = try DiscoveryFixture()
        let folder = try fixture.makeFolder("wt")
        try "gitdir: /somewhere/.git/worktrees/wt\n".write(to: folder.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(RepoDiscovery.gitKind(at: folder) == .file(gitdir: "/somewhere/.git/worktrees/wt"))

        let relative = try fixture.makeFolder("rel")
        try "gitdir: ../main/.git/modules/rel".write(to: relative.appending(path: ".git"), atomically: true, encoding: .utf8)
        let repo = DiscoveredRepo(url: relative, kind: .file(gitdir: "../main/.git/modules/rel"), depth: 1, relativePath: "rel")
        #expect(repo.gitDirectory == fixture.root.appending(path: "main/.git/modules/rel").standardizedFileURL)

        let junk = try fixture.makeFolder("junk")
        try "not a git pointer".write(to: junk.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(RepoDiscovery.gitKind(at: junk) == nil)
    }

    @Test func missingRootScansToNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "scope-missing-\(UUID().uuidString)")
        #expect(RepoDiscovery(maxDepth: 2).scan(missing).isEmpty)
    }

    @Test func originIsReadableThroughAWorktreeGitDirectory() throws {
        let fixture = try DiscoveryFixture()
        let api = try fixture.makeRepo("api")
        try fixture.git(["remote", "add", "origin", "git@github.com:acme/api.git"], in: api)
        try fixture.makeWorktree(of: api, at: "api-wt", branch: "scope/demo")

        let repos = RepoDiscovery(maxDepth: 1).scan(fixture.root)
        let origins = repos.map { GitConfigReader.originURL(gitDirectory: $0.gitDirectory) }
        #expect(origins == ["git@github.com:acme/api.git", "git@github.com:acme/api.git"])
    }
}

@Suite struct ScopeKindTests {
    private func repo(_ relativePath: String, depth: Int, secondary: Bool = false) -> DiscoveredRepo {
        DiscoveredRepo(url: URL(fileURLWithPath: "/scope/" + relativePath), kind: .directory, depth: depth,
                       relativePath: relativePath, isSecondary: secondary)
    }

    @Test func classifyCoversEveryKind() {
        #expect(ScopeKind.classify(rootExists: false, repos: []) == .missing)
        #expect(ScopeKind.classify(rootExists: false, repos: [repo("api", depth: 1)]) == .missing)
        #expect(ScopeKind.classify(rootExists: true, repos: []) == .plain)
        #expect(ScopeKind.classify(rootExists: true, repos: [repo("api", depth: 1)]) == .multiRepo)
        #expect(ScopeKind.classify(rootExists: true, repos: [repo("", depth: 0), repo("sub", depth: 1, secondary: true)]) == .repo)
    }

    @Test func secondaryReposAloneDoNotMakeAMultiRepoScope() {
        #expect(ScopeKind.classify(rootExists: true, repos: [repo("api/vendor/lib", depth: 3, secondary: true)]) == .plain)
    }
}
