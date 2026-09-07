import Foundation
import Testing
import ScopeCore
@testable import ScopeGraph

@Suite struct GraphStoreTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-graph-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private var sample: ScopeGraph {
        var graph = ScopeGraph(scopeSlug: "acme", generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        graph.repos["api"] = RepoCard(
            name: "api", remote: "acme/api", defaultBranch: "main", purpose: "The backend.",
            stack: ["node", "typescript"], entrypoints: ["src/index.ts"], related: [Relation(kind: .consumedBy, repo: "web")],
            setup: "pnpm install", test: "pnpm test", tags: ["node"], lastActivity: Date(timeIntervalSince1970: 1_799_000_000),
            generatedBy: .level0
        )
        graph.cacheKeys["api"] = "abc:1:2"
        return graph
    }

    @Test func roundTrip() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GraphStore(home: home)
        try await store.save(sample)
        #expect(store.url(for: "acme").path == home.appending(path: "graph/acme.json").path)
        let loaded = await store.load(slug: "acme")
        #expect(loaded.problem == nil && loaded.graph == sample)
        let text = try String(contentsOf: store.url(for: "acme"), encoding: .utf8)
        #expect(text.contains("\"default_branch\" : \"main\"") && text.contains("\"depends_on\"") == false && text.contains("\"consumed_by\""))

        #expect(await store.load(slug: "missing").graph == nil)
        // A hand-written minimal file decodes (arrays optional).
        try Data(#"{"scope_slug":"mini","repos":{"x":{"name":"x","purpose":"Hand written."}}}"#.utf8).write(to: store.url(for: "mini"))
        let mini = await store.load(slug: "mini").graph
        #expect(mini?.repos["x"]?.purpose == "Hand written." && mini?.repos["x"]?.stack == [] && mini?.version == 1)
    }

    @Test func manualEditPrecedenceAndFieldMerge() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GraphStore(home: home)
        try await store.save(sample)

        // Generation over a non-edited card: new values win, missing ones are kept.
        var graph = await store.loadOrEmpty(slug: "acme")
        graph.applyGenerated(RepoCard(name: "api", purpose: "Regenerated.", stack: [], generatedBy: .level0), for: "api", cacheKey: "new")
        #expect(graph.repos["api"]?.purpose == "Regenerated." && graph.repos["api"]?.stack == ["node", "typescript"])
        #expect(graph.repos["api"]?.setup == "pnpm install" && graph.cacheKeys["api"] == "new")

        // A manual edit is never overwritten, but the cache key still moves.
        var manual = graph.repos["api"]!
        manual.purpose = "My words."
        try await store.saveManual(manual, for: "api", slug: "acme")
        graph = try await store.update(slug: "acme") { g in
            g.applyGenerated(RepoCard(name: "api", purpose: "Machine words.", generatedBy: .level1), for: "api", cacheKey: "newer")
        }
        #expect(graph.repos["api"]?.purpose == "My words." && graph.repos["api"]?.edited == true)
        #expect(graph.cacheKeys["api"] == "newer")
        let reloaded = await store.load(slug: "acme").graph
        #expect(reloaded?.repos["api"]?.edited == true && reloaded?.repos["api"]?.purpose == "My words.")

        graph.resetToGenerated("api")
        graph.applyGenerated(RepoCard(name: "api", purpose: "Machine words.", generatedBy: .level1), for: "api", cacheKey: "x")
        #expect(graph.repos["api"]?.purpose == "Machine words." && graph.repos["api"]?.generatedBy == .level1)
    }

    @Test func corruptIsQuarantinedAndNewerVersionRefused() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GraphStore(home: home)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: store.url(for: "broken"))
        let broken = await store.load(slug: "broken")
        #expect(broken.graph == nil && broken.problem?.message.hasPrefix("corrupt JSON") == true)
        #expect(broken.problem?.backup?.lastPathComponent.contains("corrupt-") == true)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: "broken").path))

        var future = sample
        future.version = ScopeGraph.currentVersion + 1
        try JSONStore.save(future, to: store.url(for: "acme"))
        let original = try Data(contentsOf: store.url(for: "acme"))
        let loaded = await store.load(slug: "acme")
        #expect(loaded.graph == nil && loaded.problem?.message.contains("newer") == true)
        try await store.save(sample)   // silently dropped
        #expect(try Data(contentsOf: store.url(for: "acme")) == original)
    }
}
