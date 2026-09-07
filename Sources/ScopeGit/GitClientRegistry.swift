import Foundation
import ScopeCore

/// Hands out the single `GitClient` of each repository, so every part of the app — scopes that
/// overlap, watchers, task creation — shares the same serial queue per repo and the same global
/// fan-out cap (`maxConcurrent` git processes at once, whatever the number of repos).
public actor GitClientRegistry {
    /// Absolute path of the git executable given to every client.
    public nonisolated let gitPath: String
    /// The fan-out guard shared by every client of this registry.
    public nonisolated let semaphore: AsyncSemaphore

    private let environment: [String: String]
    private var clients: [String: GitClient] = [:]

    /// - Parameters:
    ///   - gitPath: absolute path of the git executable (see `GitLocator`).
    ///   - maxConcurrent: global cap on concurrently running git processes (clamped to at least 1).
    ///   - environment: extra variables for every client (tests pass an isolated `HOME`).
    public init(gitPath: String = "/usr/bin/git", maxConcurrent: Int = 6, environment: [String: String] = [:]) {
        self.gitPath = gitPath
        self.semaphore = AsyncSemaphore(limit: max(1, maxConcurrent))
        self.environment = environment
    }

    /// The client for `repository`, created on first use. Equivalent URLs (trailing slash, `..`,
    /// `file://` vs path form) map to the same client; symlinks are not resolved.
    public func client(for repository: URL) -> GitClient {
        let key = Self.key(for: repository)
        if let existing = clients[key] { return existing }
        let created = GitClient(
            repository: URL(fileURLWithPath: key, isDirectory: true),
            gitPath: gitPath,
            environment: environment,
            semaphore: semaphore
        )
        clients[key] = created
        return created
    }

    /// Drops the cached client of a repository (a scope was removed). In-flight commands finish normally.
    public func forget(_ repository: URL) {
        clients[Self.key(for: repository)] = nil
    }

    /// Number of clients created so far.
    public var count: Int { clients.count }

    /// Standardized absolute path, without trailing slash (`/a/b/` and `/a/b` share a client).
    nonisolated static func key(for repository: URL) -> String {
        var path = repository.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
