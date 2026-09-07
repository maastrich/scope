import Foundation
import ScopeCore
import ScopeDrivers
import ScopeGraph
import ScopeGit
import ScopeTasks

/// One card of the Graph inspector, in display order.
struct GraphCardEntry: Identifiable, Equatable {
    let key: String
    var card: RepoCard
    var id: String { key }
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

/// State of the Graph inspector (spec §4.6): the cards of the current scope, the running analysis and
/// the manual edits. Generation runs inside the `GraphGenerator` actor, off the main actor; results
/// and failures come back here (failures also go to the `ProblemCenter`).
@MainActor
@Observable
final class GraphModel {
    private(set) var scopeID: ScopeID?
    private(set) var graph: ScopeGraph?
    private(set) var isLoading = false
    private(set) var progress: GraphRunProgress?
    /// Key of the card being edited inline (`nil` = none).
    var editingKey: String?
    /// Key the card list should scroll to (set by a related link).
    var highlightedKey: String?
    /// Header filter: a case-insensitive substring over card key, name and stack; empty shows every card.
    var filter = ""

    /// `cards` narrowed by `filter`.
    var filteredCards: [GraphCardEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return cards }
        return cards.filter { entry in
            entry.key.lowercased().contains(needle) || entry.card.name.lowercased().contains(needle)
                || entry.card.stack.contains { $0.lowercased().contains(needle) }
        }
    }

    /// A stack chip click: filters on `item`, or clears the filter when it is already the filter.
    func toggleFilter(_ item: String) {
        filter = filter.caseInsensitiveCompare(item) == .orderedSame ? "" : item
    }

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let problems: ProblemCenter
    @ObservationIgnored private var runningScope: ScopeID?

    init(env: AppEnvironment, problems: ProblemCenter) {
        self.env = env
        self.problems = problems
    }

    var isGenerating: Bool { progress != nil }

    /// Cards sorted by key (`"."` first).
    var cards: [GraphCardEntry] {
        guard let graph else { return [] }
        return graph.repos.keys.sorted().map { GraphCardEntry(key: $0, card: graph.repos[$0]!) }
    }

    func card(_ key: String) -> RepoCard? { graph?.repos[key] }

    /// Graph key of a sidebar repo (`""` → `"."`).
    static func key(for repo: RepoState) -> String { TaskRepo.normalize(repo.id) }

    // MARK: Loading

    /// Loads the stored graph of `scope`. A store problem is reported once per load.
    func load(scope: ScopeState) async {
        guard scopeID != scope.id || graph == nil else { return }
        scopeID = scope.id
        editingKey = nil
        highlightedKey = nil
        filter = ""
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
    }

    // MARK: Generation

    /// Runs the generator for `scope`. `level1` is the driver-backed generator (`nil` = level 0 only).
    /// Returns the saved graph, `nil` when nothing ran or generation failed.
    @discardableResult
    func analyze(scope: ScopeState, level1: Level1Generator?, force: Bool) async -> ScopeGraph? {
        guard runningScope == nil else { return nil }
        let inputs = scope.repos.map { GraphRepoInput(key: Self.key(for: $0), url: $0.url, name: $0.shortName) }
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
    /// The default driver profile (Settings → Default driver), the one level 1 runs headless.
    var defaultDriverProfile: DriverProfile? {
        drivers.profile(id: config.preferences.defaultDriverID)
    }

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
        let summaries = result.contextSummaries()
        let scopeRepos = scope.repos.map(\.id)
        for task in tasks(in: scope.id) {
            do {
                try await env.tasks.regenerateProjection(task.id, scopeRepos: scopeRepos, repoSummaries: summaries)
            } catch {
                problems.warn("Could not refresh AGENTS.md of \(task.name)", detail: String(describing: error), scope: scope.id)
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
