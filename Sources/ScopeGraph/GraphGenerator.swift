import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// One repo to describe: its graph key (path relative to the scope root, `"."` for a repo scope),
/// its checkout and the display name of the card.
public struct GraphRepoInput: Sendable, Equatable, Hashable {
    public var key: String
    public var url: URL
    public var name: String

    public init(key: String, url: URL, name: String? = nil) {
        self.key = key
        self.url = url
        self.name = name ?? (key == "." ? url.lastPathComponent : URL(fileURLWithPath: key).lastPathComponent)
    }
}

/// Progress of one repo during `GraphGenerator.generate`.
public struct GraphProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Cache key unchanged: nothing to do.
        case skipped
        /// Level-0 generation started.
        case level0
        /// Level-1 (driver) generation started.
        case level1
        /// Card written (or kept) for this repo.
        case done
        /// Level 1 failed; the level-0 card was kept. `message` is the `Level1Error` description.
        case level1Failed(String)
    }

    public var repo: String
    /// 1-based position in the input list.
    public var index: Int
    public var total: Int
    public var phase: Phase

    public init(repo: String, index: Int, total: Int, phase: Phase) {
        self.repo = repo
        self.index = index
        self.total = total
        self.phase = phase
    }
}

/// Orchestrates generation for a scope (spec §4.6): per repo, skip when the cache key is unchanged,
/// else level 0 then optionally level 1; at most `concurrency` repos at a time; writes through `GraphStore`.
public actor GraphGenerator {
    public let store: GraphStore
    private let registry: GitClientRegistry
    private let level1: Level1Generator?
    private let semaphore: AsyncSemaphore

    /// - Parameters:
    ///   - level1: the driver-backed generator; `nil` disables level 1 even when requested.
    ///   - concurrency: repos analysed at the same time (clamped to at least 1).
    public init(store: GraphStore, registry: GitClientRegistry, level1: Level1Generator? = nil, concurrency: Int = 3) {
        self.store = store
        self.registry = registry
        self.level1 = level1
        self.semaphore = AsyncSemaphore(limit: max(1, concurrency))
    }

    /// Generates (or refreshes) the graph of `scope` and saves it. Repos absent from `repos` are removed
    /// from the graph. Progress events for a repo arrive in order: `level0` → (`level1`) → `done`, or `skipped`.
    ///
    /// - Parameters:
    ///   - useLevel1: run the driver after level 0 (ignored when the generator has no `Level1Generator`).
    ///   - force: ignore cache keys.
    @discardableResult
    public func generate(
        scope: ScopeDeclaration,
        repos: [GraphRepoInput],
        useLevel1: Bool = false,
        force: Bool = false,
        progress: @escaping @Sendable (GraphProgress) -> Void = { _ in }
    ) async throws -> ScopeGraph {
        var graph = await store.loadOrEmpty(slug: scope.slug)
        for key in graph.repos.keys where !repos.contains(where: { $0.key == key }) {
            graph.remove(key)
        }
        let scopeRoot = URL(fileURLWithPath: scope.path, isDirectory: true)
        let level1 = useLevel1 ? level1 : nil
        let total = repos.count
        let allKeys = repos.map(\.key)
        let snapshot = graph

        let results = try await withThrowingTaskGroup(of: (Int, RepoCard, String)?.self) { group in
            for (offset, repo) in repos.enumerated() {
                let index = offset + 1
                let semaphore = semaphore
                let registry = registry
                group.addTask {
                    try await semaphore.withPermit {
                        try Task.checkCancellation()
                        let client = await registry.client(for: repo.url)
                        let cacheKey = await Level0Generator.cacheKey(repo: repo.url, using: client)
                        if !force, snapshot.isCached(repo.key, cacheKey: cacheKey), snapshot.repos[repo.key] != nil {
                            progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .skipped))
                            return nil
                        }
                        progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .level0))
                        var (card, freshKey) = await Level0Generator.generate(repo: repo.url, name: repo.name, using: client)
                        if let existing = snapshot.repos[repo.key], !existing.edited {
                            card = existing.merging(generated: card)   // keep older L1 fields the L0 pass cannot produce
                        }
                        if let level1, !(snapshot.repos[repo.key]?.edited ?? false) {
                            progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .level1))
                            let others = allKeys.filter { $0 != repo.key }
                            do {
                                card = try await level1.generate(repo: repo.url, scopeRoot: scopeRoot, seed: card, otherRepos: others)
                            } catch {
                                Log.scopes.error("graph L1 failed for \(repo.name, privacy: .public): \(String(describing: error), privacy: .public)")
                                progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .level1Failed(String(describing: error))))
                            }
                        }
                        // The key is re-read after generation so a commit made meanwhile invalidates the card.
                        freshKey = await Level0Generator.cacheKey(repo: repo.url, using: client)
                        progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .done))
                        return (offset, card, freshKey)
                    }
                }
            }
            var collected: [(Int, RepoCard, String)] = []
            for try await result in group {
                if let result { collected.append(result) }
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        for (offset, card, cacheKey) in results {
            graph.applyGenerated(card, for: repos[offset].key, cacheKey: cacheKey)
        }
        graph.generatedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))   // whole seconds: round-trips through JSONStore
        try await store.save(graph)
        return graph
    }
}

public extension ScopeGraph {
    /// The cards as `TaskProjection` inputs (`AGENTS.md` purpose / stack / setup / test lines).
    func contextSummaries() -> [RepoContextSummary] {
        repos.keys.sorted().map { key in
            let card = repos[key]!
            return RepoContextSummary(path: key, purpose: card.purpose, stack: card.stack, setup: card.setup, test: card.test,
                                      teardown: card.teardown)
        }
    }
}
