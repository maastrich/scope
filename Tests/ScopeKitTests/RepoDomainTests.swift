import Testing
@testable import ScopeGraph

@Suite struct RepoDomainTests {
    @Test func inferredFromStackTagsAndName() {
        #expect(RepoDomain.infer(stack: ["node", "typescript", "next", "react"], tags: [], name: "ascension") == .frontend)
        #expect(RepoDomain.infer(stack: ["python", "make"], tags: [], name: "billing-microservice") == .backend)
        #expect(RepoDomain.infer(stack: ["node", "make"], tags: ["monorepo"], name: "storefront-front-infra") == .infra)
        #expect(RepoDomain.infer(stack: ["docker", "github actions"], tags: ["ci"], name: "web-build") == .infra)
        #expect(RepoDomain.infer(stack: ["python", "make"], tags: [], name: "acme-lambda-lib") == .library)
        #expect(RepoDomain.infer(stack: ["markdown", "css"], tags: ["design-system", "branding"], name: "design-system") == .docs)
        #expect(RepoDomain.infer(stack: ["go", "make"], tags: [], name: "gh-clean-merged") == .tooling)
        #expect(RepoDomain.infer(stack: ["node"], tags: [], name: "geo") == .data)
        #expect(RepoDomain.infer(stack: [], tags: [], name: "canonical") == .other)
        // `make` alone says nothing; the description's words tip it.
        #expect(RepoDomain.infer(stack: ["make"], tags: [], name: "platform") == .other)
        #expect(RepoDomain.infer(stack: ["make"], tags: [], name: "platform",
                                 description: "Runs the platform backend in PHP and its REST API.") == .backend)
    }

    @Test func anAnalysisDomainWinsWhenKnown() {
        var card = RepoCard(name: "web", stack: ["react"])
        #expect(RepoDomain.of(card) == .frontend)
        card.domain = "Data"
        #expect(RepoDomain.of(card) == .data)
        card.domain = "marketing"   // not a domain: inferred instead
        #expect(RepoDomain.of(card) == .frontend)
    }

    @Test func groupsFollowTheDomainOrderAndKeepKeyOrderInside() {
        let groups = RepoDomain.groups([("b-api", .backend), ("web", .frontend), ("a-api", .backend), ("admin", .frontend), ("misc", .other)])
        #expect(groups.map(\.domains) == [[.frontend], [.backend], [.other]])   // one small domain stays itself
        #expect(groups[1].keys == ["a-api", "b-api"] && groups[0].keys == ["admin", "web"])
    }

    /// A real scope had eight domains for fourteen repos: four groups of one card each left the sheet mostly empty.
    @Test func smallDomainsShareOneGroup() {
        let groups = RepoDomain.groups([("front", .frontend), ("billing", .backend), ("render", .backend), ("lambda-lib", .library),
                                        ("geo", .data), ("infra", .infra), ("ci", .infra)])
        #expect(groups.map(\.id) == ["backend", "infra", "frontend+library+data"])
        #expect(groups.last?.title == "Front · Libs · Data" && groups.last?.keys == ["front", "lambda-lib", "geo"])
    }
}
