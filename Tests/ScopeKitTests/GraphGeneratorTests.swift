import Foundation
import Synchronization
import Testing
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks
@testable import ScopeGraph

@Suite struct GraphGeneratorTests {
    /// Canned driver output; counts calls so tests can assert what ran.
    final class FakeRunner: HeadlessRunner {
        let output: String
        let calls = Mutex(0)
        init(output: String) { self.output = output }
        func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
            calls.withLock { $0 += 1 }
            return ProcessResult(exitCode: 0, terminationReason: .exit, stdout: Data(output.utf8), stderr: Data())
        }
    }

    final class Events: Sendable {
        let list = Mutex<[GraphProgress]>([])
        func append(_ p: GraphProgress) { list.withLock { $0.append(p) } }
        var all: [GraphProgress] { list.withLock { $0 } }
    }

    private func fixture() async throws -> (TestScope, [GraphRepoInput]) {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try scope.write(api, "package.json", #"{"name":"api","scripts":{"test":"jest"}}"#)
        try scope.write(api, "README.md", "# api\n\nThe backend.\n")
        try await scope.commit(in: api, "manifest")
        let web = try await scope.makeRepo("web")
        try scope.write(web, "Cargo.toml", "[package]\nname = \"web\"\n")
        try await scope.commit(in: web, "manifest")
        return (scope, [GraphRepoInput(key: "api", url: api), GraphRepoInput(key: "web", url: web)])
    }

    @Test func level0RunThenSkipWhenCached() async throws {
        let (scope, repos) = try await fixture()
        let store = GraphStore(home: scope.home)
        let generator = GraphGenerator(store: store, registry: scope.registry, concurrency: 1)
        let events = Events()

        let graph = try await generator.generate(scope: scope.declaration, repos: repos) { events.append($0) }
        #expect(graph.repos["api"]?.purpose == "The backend." && graph.repos["api"]?.test == "npm test")
        #expect(graph.repos["web"]?.stack == ["rust"] && graph.repos["web"]?.remote?.contains("web") == true)
        #expect(graph.cacheKeys.count == 2 && graph.generatedAt != nil)
        #expect(await store.load(slug: "acme").graph == graph)
        // Each repo goes L0 then done, with its index/total carried. Which repo the semaphore admits first is
        // not a contract: the task group starts its children in any order, so the interleaving is not asserted.
        let byRepo = Dictionary(grouping: events.all, by: \.repo)
        #expect(byRepo["api"]?.map { "\($0.index)/\($0.total):\($0.phase)" } == ["1/2:level0", "1/2:done"])
        #expect(byRepo["web"]?.map { "\($0.index)/\($0.total):\($0.phase)" } == ["2/2:level0", "2/2:done"])
        #expect(events.all.count == 4)

        // Nothing changed: both skipped, file untouched apart from generatedAt.
        let second = Events()
        let again = try await generator.generate(scope: scope.declaration, repos: repos) { second.append($0) }
        #expect(second.all.map(\.phase) == [.skipped, .skipped])
        #expect(again.repos == graph.repos && again.cacheKeys == graph.cacheKeys)

        // A commit in api regenerates only api; a dropped repo is removed from the graph.
        try scope.write(repos[0].url, "README.md", "# api\n\nNow different.\n")
        try await scope.commit(in: repos[0].url, "readme")
        let third = Events()
        let partial = try await generator.generate(scope: scope.declaration, repos: [repos[0]]) { third.append($0) }
        #expect(third.all.map(\.phase) == [.level0, .done])
        #expect(partial.repos["api"]?.purpose == "Now different." && partial.repos["web"] == nil && partial.cacheKeys["web"] == nil)

        // force regenerates even when cached.
        let forced = Events()
        try await generator.generate(scope: scope.declaration, repos: [repos[0]], force: true) { forced.append($0) }
        #expect(forced.all.map(\.phase) == [.level0, .done])
    }

    @Test func level1SuccessAndInvalidJSONFallBackToLevel0() async throws {
        let (scope, repos) = try await fixture()
        let store = GraphStore(home: scope.home)
        let profile = try DriverRegistry.bundledProfiles().first { $0.id == "claude-code" }!
        let good = FakeRunner(output: #"{"purpose":"From the driver.","stack":["node","fastify"],"related":[{"kind":"consumed_by","repo":"web"}],"tags":["api"]}"#)
        let generator = GraphGenerator(
            store: store, registry: scope.registry,
            level1: Level1Generator(profile: profile, runner: good, home: scope.home), concurrency: 3
        )
        let events = Events()
        let graph = try await generator.generate(scope: scope.declaration, repos: repos, useLevel1: true) { events.append($0) }
        #expect(good.calls.withLock { $0 } == 2)
        #expect(graph.repos["api"]?.purpose == "From the driver." && graph.repos["api"]?.generatedBy == .level1)
        #expect(graph.repos["api"]?.related == [Relation(kind: .consumedBy, repo: "web")])
        #expect(graph.repos["api"]?.test == "npm test")   // L0 fields survive when the driver says nothing
        let apiPhases = events.all.filter { $0.repo == "api" }.map(\.phase)
        #expect(apiPhases == [.level0, .level1, .done])

        // Level 1 not requested: driver never runs, cache skips everything.
        try await generator.generate(scope: scope.declaration, repos: repos)
        #expect(good.calls.withLock { $0 } == 2)

        // Asked for again on unchanged repos whose cards it already wrote: nothing to redo.
        try await generator.generate(scope: scope.declaration, repos: repos, useLevel1: true)
        #expect(good.calls.withLock { $0 } == 2)

        // A card an older prompt wrote is redone, once.
        #expect(graph.repos["api"]?.promptVersion == Level1Generator.promptVersion)
        _ = try await store.update(slug: "acme") { $0.repos["api"]?.promptVersion = nil }
        try await generator.generate(scope: scope.declaration, repos: repos, useLevel1: true)
        #expect(good.calls.withLock { $0 } == 3)
        try await generator.generate(scope: scope.declaration, repos: repos, useLevel1: true)
        #expect(good.calls.withLock { $0 } == 3)

        // Invalid JSON from the driver: L0 card kept, failure reported, generation still succeeds.
        let bad = FakeRunner(output: "I cannot help with that.")
        let failing = GraphGenerator(
            store: store, registry: scope.registry,
            level1: Level1Generator(profile: profile, runner: bad, home: scope.home), concurrency: 1
        )
        let failures = Events()
        let kept = try await failing.generate(scope: scope.declaration, repos: [repos[1]], useLevel1: true, force: true) { failures.append($0) }
        #expect(kept.repos["web"]?.stack == ["rust"] && kept.repos["web"]?.generatedBy == .level0)
        let phases = failures.all.map(\.phase)
        #expect(phases.count == 4 && phases[0] == .level0 && phases[1] == .level1 && phases[3] == .done)
        if case .level1Failed(let message) = phases[2] { #expect(message.contains("not JSON")) } else { Issue.record("expected level1Failed, got \(phases[2])") }

        // That card is still the quick pass's: an unchanged repo does not keep the driver away from it.
        let retried = Events()
        try await failing.generate(scope: scope.declaration, repos: [repos[1]], useLevel1: true) { retried.append($0) }
        #expect(retried.all.first?.phase == .level0 && bad.calls.withLock { $0 } == 2)

        // A manually edited card is neither overwritten nor sent to the driver.
        var manual = kept.repos["web"]!
        manual.purpose = "Mine."
        try await store.saveManual(manual, for: "web", slug: "acme")
        let calls = good.calls.withLock { $0 }
        let after = try await generator.generate(scope: scope.declaration, repos: [repos[1]], useLevel1: true, force: true)
        #expect(after.repos["web"]?.purpose == "Mine." && good.calls.withLock { $0 } == calls)
        #expect(after.contextSummaries() == [RepoContextSummary(path: "web", purpose: "Mine.", stack: ["rust"], setup: "cargo build", test: "cargo test")])
    }

    /// The facts the sheet shows — descriptions from the manifest, the README and GitHub — reach every card, the ones
    /// a cached analysis skips and the ones a person edited included; a stored command the files rule out is replaced.
    @Test func factsRefreshWithoutRegenerating() async throws {
        let (scope, local) = try await fixture()
        var repos = local
        try scope.write(repos[0].url, "package.json", #"{"name":"api","description":"The API.","scripts":{"test":"jest"}}"#)
        try await scope.commit(in: repos[0].url, "describe")
        let asked = Mutex<[String]>([])
        let answers = ["acme/api": "Serves the mobile app.", "acme/web": ""]
        let describer: GitHubDescriber = { ownerRepo in
            asked.withLock { $0.append(ownerRepo) }
            return answers[ownerRepo]
        }
        let store = GraphStore(home: scope.home)
        let generator = GraphGenerator(store: store, registry: scope.registry, concurrency: 2, describer: describer)
        let first = try await generator.generate(scope: scope.declaration, repos: repos)
        #expect(first.repos["api"]?.manifestDescription == "The API." && first.repos["api"]?.readmeSummary == "The backend.")
        #expect(asked.withLock { $0 }.isEmpty)   // local remotes: nothing to ask GitHub
        repos[0].githubRepo = "acme/api"
        repos[1].githubRepo = "acme/web"

        // A graph written before the facts: GitHub remotes, a driver's bad command, a card edited by hand.
        try await store.update(slug: "acme") { graph in
            graph.repos["api"]?.remote = "acme/api"
            graph.repos["api"]?.setup = "uv sync"
            graph.repos["api"]?.manifestDescription = nil
            graph.repos["web"]?.remote = "https://github.com/acme/web.git"
            graph.repos["web"]?.edited = true
            graph.repos["web"]?.setup = "make setup"
        }
        let refreshed = try #require(try await generator.refreshFacts(slug: "acme", repos: repos))
        #expect(Set(asked.withLock { $0 }) == ["acme/api", "acme/web"])
        #expect(refreshed.repos["api"]?.githubDescription == "Serves the mobile app." && refreshed.repos["web"]?.githubDescription == "")
        #expect(refreshed.repos["api"]?.manifestDescription == "The API.")
        #expect(refreshed.repos["api"]?.setup == "npm install")
        #expect(refreshed.repos["web"]?.setup == "make setup")   // edited: the person's command stays
        #expect(await store.load(slug: "acme").graph == refreshed)

        // Asked once: "" means GitHub has no description, not "ask again".
        #expect(try await generator.refreshFacts(slug: "acme", repos: repos) == nil)
        #expect(asked.withLock { $0 }.count == 2)

        // A cached analysis still refreshes the facts it can read from the files.
        try await store.update(slug: "acme") { $0.repos["api"]?.readmeSummary = nil }
        let skipped = try await generator.generate(scope: scope.declaration, repos: repos)
        #expect(skipped.repos["api"]?.readmeSummary == "The backend.")
    }

    @Test func anUnansweredDescriptionIsAskedAgain() async throws {
        let (scope, local) = try await fixture()
        let repos = [GraphRepoInput(key: "api", url: local[0].url, githubRepo: "acme/api"), local[1]]
        let store = GraphStore(home: scope.home)
        let calls = Mutex(0)
        let generator = GraphGenerator(store: store, registry: scope.registry, describer: { _ in calls.withLock { $0 += 1 }; return nil })
        try await generator.generate(scope: scope.declaration, repos: repos)
        #expect(try await generator.refreshFacts(slug: "acme", repos: repos) == nil)
        #expect(try await generator.refreshFacts(slug: "acme", repos: repos) == nil)
        #expect(calls.withLock { $0 } == 3)   // the analysis, then each refresh: an unanswered question is not cached
    }
}
