import Testing
@testable import ScopeGraph

@Suite struct RepoDescriptionTests {
    @Test func orderIsEditedGitHubManifestAIThenReadme() {
        var card = RepoCard(name: "front", purpose: "1. Create a personal access token.", generatedBy: .level0,
                            githubDescription: "The Acme web app.", manifestDescription: "Monorepo of the front.",
                            readmeSummary: "Front of the platform.")
        #expect(RepoDescription.choose(for: card) == RepoDescription(text: "The Acme web app.", source: .github))
        card.githubDescription = ""   // asked, GitHub has none
        #expect(RepoDescription.choose(for: card)?.source == .manifest)
        card.manifestDescription = nil
        #expect(RepoDescription.choose(for: card) == RepoDescription(text: "Front of the platform.", source: .readme))
        card.edited = true
        card.purpose = "My own words."
        #expect(RepoDescription.choose(for: card) == RepoDescription(text: "My own words.", source: .edited))
    }

    @Test func aManifestDescriptionThatOnlyNamesTheRepoIsSkipped() {
        let card = RepoCard(name: "auth", manifestDescription: "Auth", readmeSummary: "Adds single sign-on to the API.")
        #expect(RepoDescription.choose(for: card)?.source == .readme)
        let monorepo = RepoCard(name: "linger", manifestDescription: "Linger Monorepo")
        #expect(RepoDescription.choose(for: monorepo) == nil)
    }

    @Test func aiPurposeComesBeforeTheReadme() {
        let card = RepoCard(name: "api", purpose: "Serves the GraphQL API; work here for resolvers.", generatedBy: .level1,
                            promptVersion: 3, readmeSummary: "Welcome to the API.")
        #expect(RepoDescription.choose(for: card)?.source == .ai)
    }

    /// A card stored before `readme_summary` existed only has the README's raw first paragraph as its purpose.
    @Test func aLegacyPurposeIsOnlyUsedWhenItReadsAsProse() {
        let instructions = RepoCard(name: "front", purpose: "1. Create a personal access token.")
        #expect(RepoDescription.choose(for: instructions) == nil)
        let prose = RepoCard(name: "geo", purpose: "Generates the map tiles. Run it with node.")
        #expect(RepoDescription.choose(for: prose) == RepoDescription(text: "Generates the map tiles.", source: .readme))
        #expect(RepoDescription.choose(for: RepoCard(name: "x")) == nil)
    }

    @Test func subtitleIsOwnerRepoNeverAPath() {
        #expect(RepoIdentity.subtitle(remote: "acme-org/acme-front", key: "front", name: "front") == "acme-org/acme-front")
        #expect(RepoIdentity.subtitle(remote: "git@gitlab.com:team/sub/api.git", key: "api", name: "api") == "sub/api")
        #expect(RepoIdentity.subtitle(remote: "https://github.com/acme/web.git", key: "web", name: "web") == "acme/web")
        #expect(RepoIdentity.subtitle(remote: nil, key: "services/api", name: "api") == "services/api")
        #expect(RepoIdentity.subtitle(remote: nil, key: "api", name: "api") == nil)
        #expect(RepoIdentity.subtitle(remote: nil, key: ".", name: "scope") == nil)
    }
}
