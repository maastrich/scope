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
    /// `owner/repo` when the repo's origin is on GitHub: the repository `gh repo view` can describe. The card only
    /// keeps `owner/repo`, which a local or GitLab remote has too, so the caller — who has the remote's host — says.
    public var githubRepo: String?

    public init(key: String, url: URL, name: String? = nil, githubRepo: String? = nil) {
        self.key = key
        self.url = url
        self.githubRepo = githubRepo
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

/// Asks GitHub for a repository's description (`gh repo view <owner/repo> --json description`): `""` when it has
/// none, `nil` when the question could not be answered (no `gh`, offline, not logged in) — which is not cached, so
/// the next analysis asks again.
public typealias GitHubDescriber = @Sendable (_ ownerRepo: String) async -> String?

/// Orchestrates generation for a scope (spec §4.6): per repo, skip when the cache key is unchanged,
/// else level 0 then optionally level 1; at most `concurrency` repos at a time; writes through `GraphStore`.
public actor GraphGenerator {
    public let store: GraphStore
    private let registry: GitClientRegistry
    private let level1: Level1Generator?
    private let semaphore: AsyncSemaphore
    private let describer: GitHubDescriber?

    /// - Parameters:
    ///   - level1: the driver-backed generator; `nil` disables level 1 even when requested.
    ///   - concurrency: repos analysed at the same time (clamped to at least 1).
    public init(store: GraphStore, registry: GitClientRegistry, level1: Level1Generator? = nil, concurrency: Int = 3,
                describer: GitHubDescriber? = nil) {
        self.describer = describer
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

        let results = try await withThrowingTaskGroup(of: Outcome.self) { group in
            for (offset, repo) in repos.enumerated() {
                let index = offset + 1
                let semaphore = semaphore
                let registry = registry
                group.addTask {
                    try await semaphore.withPermit {
                        try Task.checkCancellation()
                        let client = await registry.client(for: repo.url)
                        let cacheKey = await Level0Generator.cacheKey(repo: repo.url, using: client)
                        // An unchanged repo is only done when its card came from the level asked for, and from
                        // the prompt as it stands: the cache
                        // key says nothing of who wrote the card, and an AI pass that skipped every repo the quick
                        // pass had seen left the README's first paragraph as the purpose.
                        if !force, snapshot.isCached(repo.key, cacheKey: cacheKey), let existing = snapshot.repos[repo.key],
                           level1 == nil || existing.edited
                            || (existing.generatedBy == .level1 && existing.promptVersion == Level1Generator.promptVersion) {
                            progress(GraphProgress(repo: repo.name, index: index, total: total, phase: .skipped))
                            return .skipped(offset, Level0Generator.analyze(repo: repo.url))
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
                        return .generated(offset, card, freshKey, Level0Generator.analyze(repo: repo.url))
                    }
                }
            }
            var collected: [Outcome] = []
            for try await result in group { collected.append(result) }
            return collected.sorted { $0.offset < $1.offset }
        }

        for outcome in results {
            let key = repos[outcome.offset].key
            if case .generated(_, let card, let cacheKey, _) = outcome {
                graph.applyGenerated(card, for: key, cacheKey: cacheKey)
            }
            Self.applyFacts(outcome.analysis, to: &graph, key: key, repo: repos[outcome.offset].url)
        }
        if let describer {
            await Self.describe(&graph, repos: repos, force: force, describer: describer, limit: semaphore)
        }
        graph.generatedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))   // whole seconds: round-trips through JSONStore
        try await store.save(graph)
        return graph
    }
}

extension GraphGenerator {
    enum Outcome: Sendable {
        case skipped(Int, Level0Analysis)
        case generated(Int, RepoCard, String, Level0Analysis)

        var offset: Int {
            switch self {
            case .skipped(let offset, _), .generated(let offset, _, _, _): offset
            }
        }

        var analysis: Level0Analysis {
            switch self {
            case .skipped(_, let analysis), .generated(_, _, _, let analysis): analysis
            }
        }
    }

    /// What the files say, applied whatever wrote the card: the manifest and README descriptions, and — on a card
    /// nobody edited — a setup or test command the files rule out, replaced by the quick analysis's own.
    static func applyFacts(_ analysis: Level0Analysis, to graph: inout ScopeGraph, key: String, repo: URL) {
        graph.applyFacts(key, manifestDescription: .some(analysis.manifestDescription), readmeSummary: .some(analysis.readmeSummary))
        guard var card = graph.repos[key], !card.edited else { return }
        if let setup = card.setup, SetupCommandCheck.problem(setup, in: repo) != nil { card.setup = analysis.setup }
        if let test = card.test, SetupCommandCheck.problem(test, in: repo) != nil { card.test = analysis.test }
        graph.repos[key] = card
    }

    /// Fills the GitHub description of every card with a GitHub remote that has none yet (all of them with
    /// `force`), a few repos at a time.
    static func describe(_ graph: inout ScopeGraph, repos: [GraphRepoInput], force: Bool, describer: @escaping GitHubDescriber,
                         limit: AsyncSemaphore) async {
        let wanted: [(String, String)] = repos.compactMap { repo in
            guard let card = graph.repos[repo.key], force || card.githubDescription == nil, let ownerRepo = repo.githubRepo else { return nil }
            return (repo.key, ownerRepo)
        }
        let answers = await withTaskGroup(of: (String, String?).self) { group in
            for (key, ownerRepo) in wanted {
                group.addTask { await limit.withPermit { (key, await describer(ownerRepo)) } }
            }
            var answers: [(String, String?)] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        for (key, description) in answers {
            if let description { graph.applyFacts(key, githubDescription: description.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// Refreshes what a stored graph says about its repos without generating anything: the descriptions from the
    /// files and from GitHub, and commands the files rule out. What the sheet runs when it opens a graph written
    /// before those facts existed; touches nothing but the graph file. Returns `nil` when nothing changed.
    public func refreshFacts(slug: String, repos: [GraphRepoInput]) async throws -> ScopeGraph? {
        let before = await store.loadOrEmpty(slug: slug)
        var graph = before
        for repo in repos where graph.repos[repo.key] != nil {
            Self.applyFacts(Level0Generator.analyze(repo: repo.url), to: &graph, key: repo.key, repo: repo.url)
        }
        if let describer {
            await Self.describe(&graph, repos: repos, force: false, describer: describer, limit: semaphore)
        }
        guard graph != before else { return nil }
        // The file may have changed while gh answered: apply the refreshed cards' facts over what is there now.
        return try await store.update(slug: slug) { current in
            for (key, card) in graph.repos where current.repos[key] != nil {
                current.applyFacts(key, manifestDescription: .some(card.manifestDescription), readmeSummary: .some(card.readmeSummary),
                                   githubDescription: card.githubDescription)
                if !(current.repos[key]?.edited ?? true) {
                    current.repos[key]?.setup = card.setup
                    current.repos[key]?.test = card.test
                }
            }
        }
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
