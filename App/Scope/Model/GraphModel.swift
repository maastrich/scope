import Foundation
import ScopeCore
import ScopeDrivers
import ScopeGraph
import ScopeGit
import ScopeTasks

/// One repo of the Graph sheet, with what every view shows of it worked out once.
struct GraphCardEntry: Identifiable, Equatable {
    let key: String
    var card: RepoCard
    /// Stack and tags, merged and deduplicated.
    let tags: [DisplayTag]
    let domain: RepoDomain
    let description: RepoDescription?
    /// `owner/repo`, or the path in the scope; `nil` when it would repeat the name.
    let subtitle: String?
    var id: String { key }

    init(key: String, card: RepoCard) {
        self.key = key
        self.card = card
        tags = TagMerge.merge(card)
        domain = RepoDomain.of(card, key: key)
        description = RepoDescription.choose(for: card)
        subtitle = RepoIdentity.subtitle(remote: card.remote, key: key, name: card.name)
    }
}

/// The three ways the sheet shows a scope's repos.
enum GraphMode: String, Codable, CaseIterable, Sendable {
    case cards, list, graph

    var title: String {
        switch self {
        case .cards: "Cards"
        case .list: "List"
        case .graph: "Graph"
        }
    }
}

/// What the sheet remembers per scope: the view, and the domain groups folded in the Cards view.
struct GraphPlace: Codable, Sendable, Equatable {
    var mode: GraphMode = .cards
    /// `DomainGroup.id`s.
    var collapsed: Set<String> = []
}

/// Progress of the running analysis, as shown in the inspector header.
struct GraphRunProgress: Equatable {
    var finished = 0
    var total = 0
    var current: String?
    var level1Failures: [String] = []

    var caption: String {
        let count = "\(finished)/\(total)"
        return current.map { "\(count) · \($0)" } ?? count
    }
}

/// State of the Graph sheet (spec §4.6): the cards of the current scope, the filter its three views share, the
/// running analysis and the manual edits. Generation runs inside the `GraphGenerator` actor, off the main actor;
/// results and failures come back here (failures also go to the `ProblemCenter`).
@MainActor
@Observable
final class GraphModel {
    private(set) var scopeID: ScopeID?
    private(set) var graph: ScopeGraph? {
        didSet { rebuild() }
    }
    private(set) var isLoading = false
    private(set) var progress: GraphRunProgress?
    /// Key of the card being edited inline (`nil` = none).
    var editingKey: String?
    /// Key the views should bring into view and mark (a related link, the sidebar's "See Graph", a list row).
    var highlightedKey: String?
    /// The repo whose card the Graph view shows beside the drawing, and the List view's selected row.
    var selectedKey: String?
    /// Cards whose Details section is open.
    var expanded: Set<String> = []
    /// The filter the three views share.
    var filter = GraphFilter()

    /// Every card, sorted by key (`"."` first).
    private(set) var cards: [GraphCardEntry] = []
    /// Every link between two repos of the graph, whatever the filter: the drawing stays put while filtering.
    private(set) var edges: [GraphEdge] = []
    private(set) var layout = GraphLayout(slots: [:], isolated: [], columns: 0, rows: 0)

    /// `cards` narrowed by `filter`.
    var filteredCards: [GraphCardEntry] {
        guard !filter.isEmpty else { return cards }
        return cards.filter(matches)
    }

    func matches(_ entry: GraphCardEntry) -> Bool {
        filter.matches(key: entry.key, card: entry.card, tags: entry.tags, domain: entry.domain, description: entry.description?.text)
    }

    /// The groups of the Cards view, made from every card so a group does not change name while filtering, then
    /// narrowed to the filtered cards (an emptied group is dropped).
    var groups: [(group: DomainGroup, entries: [GraphCardEntry])] {
        let filtered = filteredCards
        let byKey = Dictionary(uniqueKeysWithValues: filtered.map { ($0.key, $0) })
        return RepoDomain.groups(cards.map { ($0.key, $0.domain) }).compactMap { group in
            let entries = group.keys.compactMap { byKey[$0] }
            return entries.isEmpty ? nil : (group, entries)
        }
    }

    /// The group a card is shown in.
    func group(of key: String) -> DomainGroup? {
        RepoDomain.groups(cards.map { ($0.key, $0.domain) }).first { $0.keys.contains(key) }
    }

    func entry(_ key: String) -> GraphCardEntry? { cards.first { $0.key == key } }

    /// Links into and out of `key`: (depends on, used by).
    func relations(of key: String) -> (out: [String], in: [String]) {
        (edges.filter { $0.from == key }.map(\.to), edges.filter { $0.to == key }.map(\.from))
    }

    private func rebuild() {
        guard let graph else {
            cards = []
            edges = []
            layout = GraphLayout(slots: [:], isolated: [], columns: 0, rows: 0)
            return
        }
        cards = graph.repos.keys.sorted().map { GraphCardEntry(key: $0, card: graph.repos[$0]!) }
        edges = GraphEdge.build(graph.repos)
        layout = GraphLayout.layered(keys: graph.repos.keys.sorted(), edges: edges)
    }

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var runningScope: ScopeID?

    init(env: AppEnvironment, problems: ProblemCenter) {
        self.env = env
        self.problems = problems
    }

    var isGenerating: Bool { progress != nil }

    func card(_ key: String) -> RepoCard? { graph?.repos[key] }

    /// Graph key of a sidebar repo (`""` → `"."`).
    static func key(for repo: RepoState) -> String { TaskRepo.normalize(repo.id) }

    /// What the generator needs of each repo of `scope`, GitHub's `owner/repo` included when origin is on GitHub.
    static func inputs(of scope: ScopeState) -> [GraphRepoInput] {
        scope.repos.map { repo in
            // The facts may not be loaded yet when the sheet opens: the checkout's own config says the same.
            let remote = repo.facts?.remote
                ?? GitConfigReader.originURL(gitDirectory: repo.url.appending(path: ".git")).flatMap(RemoteInfo.init(remote:))
            let github = remote.flatMap { $0.host?.contains("github") == true ? $0.fullName : nil }
            return GraphRepoInput(key: key(for: repo), url: repo.url, name: repo.shortName, githubRepo: github)
        }
    }

    // MARK: Loading

    /// Loads the stored graph of `scope`. A store problem is reported once per load. Then, off the main actor, the
    /// facts a graph written by an older build lacks — the descriptions — are filled in: only the graph file is
    /// written, never the repos.
    func load(scope: ScopeState) async {
        guard scopeID != scope.id || graph == nil else { return }
        // `highlightedKey` survives: the sidebar's "See Graph" sets it before the sheet loads.
        scopeID = scope.id
        editingKey = nil
        selectedKey = nil
        expanded = []
        filter = GraphFilter()
        isLoading = true
        let slug = scope.declaration.slug
        let (loaded, problem) = await env.graphStore.load(slug: slug)
        guard scopeID == scope.id else { return }
        isLoading = false
        graph = loaded ?? ScopeGraph(scopeSlug: slug)
        if let problem {
            problems.warn("Graph of \(scope.name) could not be loaded", detail: problem.message, scope: scope.id,
                          actions: [.reveal(problem.backup?.path ?? problem.file.path)])
        }
        guard loaded?.repos.isEmpty == false, problem == nil else { return }
        let inputs = Self.inputs(of: scope)
        let generator = env.makeGraphGenerator(level1: nil)
        if let refreshed = try? await generator.refreshFacts(slug: slug, repos: inputs), scopeID == scope.id, runningScope == nil {
            graph = refreshed
        }
    }

    // MARK: Generation

    /// Runs the generator for `scope`. `level1` is the driver-backed generator (`nil` = level 0 only).
    /// Returns the saved graph, `nil` when nothing ran or generation failed.
    @discardableResult
    func analyze(scope: ScopeState, level1: Level1Generator?, force: Bool) async -> ScopeGraph? {
        guard runningScope == nil else { return nil }
        let inputs = Self.inputs(of: scope)
        guard !inputs.isEmpty else {
            problems.warn("Nothing to analyze in \(scope.name)", detail: "The scope has no repository.", scope: scope.id)
            return nil
        }
        runningScope = scope.id
        scopeID = scope.id
        progress = GraphRunProgress(total: inputs.count)
        defer {
            runningScope = nil
            progress = nil
        }
        let generator = env.makeGraphGenerator(level1: level1)
        do {
            let result = try await generator.generate(scope: scope.declaration, repos: inputs, useLevel1: level1 != nil, force: force) { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            let failures = progress?.level1Failures ?? []
            if !failures.isEmpty {
                problems.warn("AI analysis failed for \(failures.count) \(failures.count == 1 ? "repo" : "repos") of \(scope.name)",
                              detail: failures.joined(separator: "\n"), scope: scope.id)
            }
            if scopeID == scope.id { graph = result }
            return result
        } catch {
            problems.error("Could not analyze \(scope.name)", detail: String(describing: error), scope: scope.id)
            return nil
        }
    }

    private func apply(_ event: GraphProgress) {
        guard var progress else { return }
        switch event.phase {
        case .level0, .level1:
            progress.current = event.repo
        case .skipped, .done:
            progress.finished += 1
            if progress.current == event.repo { progress.current = nil }
        case .level1Failed(let message):
            progress.level1Failures.append("\(event.repo): \(message)")
        }
        self.progress = progress
    }

    // MARK: Manual edits

    /// Stores a hand-edited card; generation never overwrites it afterwards.
    func setManual(_ card: RepoCard, for key: String) async {
        guard let slug = graph?.scopeSlug else { return }
        do {
            graph = try await env.graphStore.saveManual(card, for: key, slug: slug)
        } catch {
            problems.error("Could not save the card of \(card.name)", detail: String(describing: error), scope: scopeID)
        }
        editingKey = nil
    }

    /// Drops the manual flag; the caller re-runs the analysis so the card is regenerated.
    func resetToGenerated(_ key: String) async {
        guard let slug = graph?.scopeSlug else { return }
        do {
            var stored = await env.graphStore.loadOrEmpty(slug: slug)
            stored.resetToGenerated(key)
            try await env.graphStore.save(stored)
            graph = stored
        } catch {
            problems.error("Could not reset the card", detail: String(describing: error), scope: scopeID)
        }
        editingKey = nil
    }
}

// MARK: - AppModel glue

extension AppModel {
    /// The driver level 1 runs headless: Settings → Default driver, or automatic (`defaultProfile`).
    var defaultDriverProfile: DriverProfile? { defaultProfile }

    /// Why "Analyze with AI" is unavailable, `nil` when it can run.
    var level1Unavailability: String? {
        guard let profile = defaultDriverProfile else { return "No default driver (Settings)." }
        guard let argv = profile.headless, !argv.isEmpty else {
            return "The \(profile.name) driver profile has no headless argv."
        }
        return nil
    }

    /// Analyzes a scope: level 0 (README, manifests, git log), plus the default driver when `withAI`.
    /// Once done, the `AGENTS.md` of the scope's tasks is regenerated so it carries the purposes.
    func analyzeGraph(scope: ScopeState, withAI: Bool, force: Bool = false) async {
        var level1: Level1Generator?
        if withAI {
            guard let profile = defaultDriverProfile, level1Unavailability == nil else {
                problems.warn("Analyze with AI is unavailable", detail: level1Unavailability, scope: scope.id,
                              actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
                return
            }
            let shell = await env.shell.environment()
            level1 = Level1Generator(profile: profile, runner: SubprocessHeadlessRunner(path: shell.path, shell: shell.shell), home: env.home)
        }
        guard let result = await graph.analyze(scope: scope, level1: level1, force: force) else { return }
        await refreshContextFiles(of: scope, summaries: result.contextSummaries())
    }

    /// Rewrites the context file of every task of `scope`: after an analysis, or when the scope's own context
    /// changed.
    func refreshContextFiles(of scope: ScopeState, summaries known: [RepoContextSummary]? = nil) async {
        let summaries: [RepoContextSummary]
        if let known { summaries = known } else { summaries = await graphSummaries(for: scope) }
        let scopeRepos = scope.repos.map(\.id)
        for task in tasks(in: scope.id) {
            do {
                try await env.tasks.regenerateProjection(task.id, scopeContext: scope.declaration.context, scopeRepos: scopeRepos,
                                                         repoSummaries: summaries, contextFiles: contextFileNames)
            } catch {
                problems.warn("Could not refresh the context file of \(task.name)", detail: String(describing: error), scope: scope.id)
            }
        }
    }

    /// The stored cards of a scope as `AGENTS.md` inputs.
    func graphSummaries(for scope: ScopeState) async -> [RepoContextSummary] {
        await env.graphStore.loadOrEmpty(slug: scope.declaration.slug).contextSummaries()
    }

    /// Task sandboxes of a base repo (for the checkout picker).
    func sandboxes(of repo: RepoState, in scope: ScopeState) -> [(task: TaskState, repo: TaskRepo)] {
        let key = GraphModel.key(for: repo)
        return tasks(in: scope.id).compactMap { task in
            task.activeRepos.first { $0.repoRelativePath == key }.map { (task, $0) }
        }
    }
}
