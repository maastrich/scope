import Testing
@testable import ScopeGraph

@Suite struct GraphFilterTests {
    private let web = RepoCard(name: "web", remote: "acme/web", stack: ["react", "typescript"], tags: ["storefront"])
    private let api = RepoCard(name: "api", remote: "acme/api", stack: ["node", "typescript"], tags: ["graphql"])
    private let infra = RepoCard(name: "infra", remote: "acme/infra", stack: ["terraform"])

    private func matches(_ filter: GraphFilter, _ key: String, _ card: RepoCard, _ domain: RepoDomain, description: String? = nil) -> Bool {
        filter.matches(key: key, card: card, tags: TagMerge.merge(card), domain: domain, description: description)
    }

    @Test func textMatchesEveryWordAnywhere() {
        let filter = GraphFilter(text: "acme store")
        #expect(matches(filter, "web", web, .frontend))
        #expect(!matches(filter, "api", api, .backend))
        #expect(matches(GraphFilter(text: "checkout"), "web", web, .frontend, description: "Catalogue and checkout pages."))
        #expect(matches(GraphFilter(text: "back"), "api", api, .backend))   // the domain's title
        #expect(matches(GraphFilter(text: "   "), "api", api, .backend))
    }

    @Test func chipsWidenWithinAKindAndNarrowAcrossKinds() {
        var filter = GraphFilter()
        filter.toggle(domain: .frontend)
        filter.toggle(domain: .backend)
        #expect(matches(filter, "web", web, .frontend) && matches(filter, "api", api, .backend))
        #expect(!matches(filter, "infra", infra, .infra))
        filter.toggle(tag: "node")
        #expect(!matches(filter, "web", web, .frontend) && matches(filter, "api", api, .backend))
        filter.toggle(tag: "node")
        #expect(filter.tags.isEmpty)
        filter = GraphFilter(tags: ["terraform", "react"])
        #expect(matches(filter, "web", web, .frontend) && matches(filter, "infra", infra, .infra) && !matches(filter, "api", api, .backend))
        #expect(GraphFilter().isEmpty && !filter.isEmpty)
    }

    @Test func facetsCountCardsMostUsedFirst() {
        let tags = GraphFacets.tags([TagMerge.merge(web), TagMerge.merge(api), TagMerge.merge(infra)])
        #expect(tags.map(\.key) == ["typescript"])
        let all = GraphFacets.tags([TagMerge.merge(web), TagMerge.merge(api)], includeSingles: true)
        #expect(all.first == GraphFacets.Count(key: "typescript", label: "typescript", count: 2))
        #expect(all.dropFirst().map(\.label) == ["graphql", "node", "react", "storefront"])
        let domains = GraphFacets.domains([.backend, .frontend, .backend])
        #expect(domains.map(\.domain) == [.frontend, .backend] && domains.map(\.count) == [1, 2])
    }
}
