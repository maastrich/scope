import Testing
@testable import ScopeGraph

@Suite struct GraphLayoutTests {
    @Test func edgesComeFromBothEndsOnceEach() {
        let repos: [String: RepoCard] = [
            "front": RepoCard(name: "front"),
            "auth": RepoCard(name: "auth", related: [Relation(kind: .consumedBy, repo: "front")]),
            "infra": RepoCard(name: "infra", related: [Relation(kind: .consumedBy, repo: "front"), Relation(kind: .dependsOn, repo: "auth"),
                                                       Relation(kind: .dependsOn, repo: "gone"), Relation(kind: .dependsOn, repo: "infra")]),
            "billing": RepoCard(name: "billing", related: [Relation(kind: .dependsOn, repo: "auth")]),
        ]
        var withDuplicate = repos
        withDuplicate["front"] = RepoCard(name: "front", related: [Relation(kind: .dependsOn, repo: "auth")])
        let expected = [GraphEdge(from: "billing", to: "auth"), GraphEdge(from: "front", to: "auth"),
                        GraphEdge(from: "front", to: "infra"), GraphEdge(from: "infra", to: "auth")]
        #expect(GraphEdge.build(repos) == expected)
        #expect(GraphEdge.build(withDuplicate) == expected)
        #expect(GraphEdge.neighbours(of: "auth", in: expected) == ["front", "infra", "billing"])
    }

    @Test func dependentsSitAboveTheirDependenciesAndIsolatedReposStayApart() {
        let edges = [GraphEdge(from: "web", to: "api"), GraphEdge(from: "api", to: "auth"), GraphEdge(from: "web", to: "ui")]
        let layout = GraphLayout.layered(keys: ["web", "api", "auth", "ui", "docs", "scratch"], edges: edges)
        #expect(layout.isolated == ["docs", "scratch"])
        #expect(layout.slots["docs"] == nil)
        #expect(layout.slots["web"]!.row == 0 && layout.slots["api"]!.row == 1 && layout.slots["ui"]!.row == 1 && layout.slots["auth"]!.row == 2)
        for edge in edges { #expect(layout.slots[edge.from]!.row < layout.slots[edge.to]!.row) }
        #expect(layout.rows == 3 && layout.columns == 2)
    }

    @Test func sameGraphSamePlacementWhateverTheInputOrder() {
        let keys = (0..<30).map { "repo-\($0)" }
        var edges: [GraphEdge] = []
        for index in 1..<20 { edges.append(GraphEdge(from: "repo-\(index % 5)", to: "repo-\(index + 5)")) }
        edges.append(GraphEdge(from: "repo-12", to: "repo-3"))
        let one = GraphLayout.layered(keys: keys, edges: edges)
        let two = GraphLayout.layered(keys: keys.reversed(), edges: edges.reversed() + edges)
        #expect(one == two)
        #expect(one.isolated == ["repo-25", "repo-26", "repo-27", "repo-28", "repo-29", "repo-5"])
        // No two repos share a slot.
        let slots = one.slots.values.map { "\($0.row):\($0.column)" }
        #expect(Set(slots).count == slots.count)
    }

    @Test func cyclesTerminateAndWideLayersWrap() {
        let cycle = [GraphEdge(from: "a", to: "b"), GraphEdge(from: "b", to: "c"), GraphEdge(from: "c", to: "a")]
        let layout = GraphLayout.layered(keys: ["a", "b", "c"], edges: cycle)
        #expect(layout.slots.count == 3 && layout.rows == 3)

        let hub = (0..<14).map { GraphEdge(from: "front", to: "lib-\($0)") }
        let wide = GraphLayout.layered(keys: ["front"] + (0..<14).map { "lib-\($0)" }, edges: hub, maxPerRow: 6)
        #expect(wide.columns == 6 && wide.rows == 4)   // the hub, then 6 + 6 + 2
        #expect(wide.slots["front"]!.column == 2.5)     // centred over the widest row
    }

    /// Thirty services using one library each used to share the top row with the front ends; a service now sits right
    /// above what it uses.
    @Test func aRepoNothingDependsOnSitsRightAboveItsDependencies() {
        let edges = [GraphEdge(from: "web", to: "api"), GraphEdge(from: "api", to: "auth"), GraphEdge(from: "auth", to: "infra"),
                     GraphEdge(from: "worker", to: "infra")]
        let layout = GraphLayout.layered(keys: ["web", "api", "auth", "infra", "worker"], edges: edges)
        #expect(layout.slots["web"]!.row == 0 && layout.slots["infra"]!.row == 3)
        #expect(layout.slots["worker"]!.row == 2)
    }

    @Test func barycentreSweepsUncrossTwoLayers() {
        // b depends on y, a on x: sorted by key the bottom layer would read x, y under a, b anyway; flip the names so
        // the key order crosses and the sweep has to fix it.
        let edges = [GraphEdge(from: "a", to: "z"), GraphEdge(from: "b", to: "y")]
        let layout = GraphLayout.layered(keys: ["a", "b", "y", "z"], edges: edges)
        let aLeftOfB = layout.slots["a"]!.column < layout.slots["b"]!.column
        let zLeftOfY = layout.slots["z"]!.column < layout.slots["y"]!.column
        #expect(aLeftOfB == zLeftOfY)
    }
}
