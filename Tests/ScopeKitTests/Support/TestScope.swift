import Foundation
import ScopeCore
import ScopeGit

/// A throwaway scope for M2 tests: a temp `SCOPE_HOME`, a scope folder holding real repos, each
/// with a bare `origin` so `origin/<default>` and `origin/HEAD` exist. Git runs with an isolated
/// `HOME`. Everything is removed on deinit.
final class TestScope: Sendable {
    let root: URL
    /// Temp `SCOPE_HOME`.
    let home: URL
    /// The scope folder (contains the repos, or is itself a repo).
    let scopeRoot: URL
    let gitPath: String
    let registry: GitClientRegistry
    let environment: [String: String]
    /// The declaration of `scopeRoot` (stable id for the lifetime of the fixture).
    let declaration: ScopeDeclaration

    private init(root: URL, home: URL, scopeRoot: URL, gitPath: String, registry: GitClientRegistry, environment: [String: String]) {
        self.declaration = ScopeDeclaration(path: scopeRoot.path, name: "acme", slug: "acme")
        self.root = root
        self.home = home
        self.scopeRoot = scopeRoot
        self.gitPath = gitPath
        self.registry = registry
        self.environment = environment
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static func make() async throws -> TestScope {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scope-m2-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .standardizedFileURL
        let home = root.appending(path: "scope-home", directoryHint: .isDirectory)
        let gitHome = root.appending(path: "git-home", directoryHint: .isDirectory)
        let scopeRoot = root.appending(path: "acme", directoryHint: .isDirectory)
        for dir in [home, gitHome, scopeRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try ScopeHome.ensureLayout(at: home)
        let environment: [String: String] = [
            "HOME": gitHome.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Scope Tests",
            "GIT_AUTHOR_EMAIL": "tests@scope.invalid",
            "GIT_COMMITTER_NAME": "Scope Tests",
            "GIT_COMMITTER_EMAIL": "tests@scope.invalid",
        ]
        let gitPath = try await GitLocator().locate().path
        let registry = GitClientRegistry(gitPath: gitPath, maxConcurrent: 4, environment: environment)
        return TestScope(root: root, home: home, scopeRoot: scopeRoot, gitPath: gitPath, registry: registry, environment: environment)
    }

    func client(for checkout: URL) async -> GitClient {
        await registry.client(for: checkout)
    }

    /// `git init -b main` + one commit of `README.md` at `<scopeRoot>/<relativePath>` (`"."` = the scope
    /// itself). With `withOrigin`, a bare `<root>/remotes/<name>.git` is pushed and set as `origin`.
    @discardableResult
    func makeRepo(_ relativePath: String, withOrigin: Bool = true) async throws -> URL {
        let repo = relativePath == "." ? scopeRoot : scopeRoot.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let client = await client(for: repo)
        try await client.run(["init", "-q", "-b", "main"])
        try write(repo, "README.md", "# \(relativePath)\n")
        try await commit(in: repo, "initial")
        if withOrigin {
            let bare = root.appending(path: "remotes/\(relativePath.replacingOccurrences(of: "/", with: "-")).git", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            try await client.run(["init", "-q", "--bare", "-b", "main", bare.path])
            try await client.run(["remote", "add", "origin", bare.path])
            try await client.run(["push", "-q", "-u", "origin", "main"])
            try await client.run(["remote", "set-head", "origin", "-a"])
        }
        return repo
    }

    func write(_ checkout: URL, _ name: String, _ content: String) throws {
        let file = checkout.appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func commit(in checkout: URL, _ message: String) async throws {
        let client = await client(for: checkout)
        try await client.run(["add", "-A"])
        try await client.run(["commit", "-q", "-m", message])
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
