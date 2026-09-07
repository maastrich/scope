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
        // Progress order with concurrency 1: api L0, api done, web L0, web done — index/total carried.
        #expect(events.all.map { "\($0.repo):\($0.index)/\($0.total):\($0.phase)" } == [
            "api:1/2:level0", "api:1/2:done", "web:2/2:level0", "web:2/2:done",
        ])

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

        // A manually edited card is neither overwritten nor sent to the driver.
        var manual = kept.repos["web"]!
        manual.purpose = "Mine."
        try await store.saveManual(manual, for: "web", slug: "acme")
        let calls = good.calls.withLock { $0 }
        let after = try await generator.generate(scope: scope.declaration, repos: [repos[1]], useLevel1: true, force: true)
        #expect(after.repos["web"]?.purpose == "Mine." && good.calls.withLock { $0 } == calls)
        #expect(after.contextSummaries() == [RepoContextSummary(path: "web", purpose: "Mine.", stack: ["rust"], setup: "cargo build", test: "cargo test")])
    }
}
