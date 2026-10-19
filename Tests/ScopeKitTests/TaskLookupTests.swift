import Testing
@testable import ScopeControl

/// `scope task archive <slug>` finds the live task of that slug, not the archived namesake of another scope.
@Suite struct TaskLookupTests {
    private let acmeArchived = TaskLookup.Candidate(id: "t1", slug: "health", scopeID: "A", scopeSlug: "acme", isArchived: true)
    private let betaLive = TaskLookup.Candidate(id: "t2", slug: "health", scopeID: "B", scopeSlug: "beta", isArchived: false)
    private let gammaLive = TaskLookup.Candidate(id: "t3", slug: "health", scopeID: "C", scopeSlug: "gamma", isArchived: false)
    private let other = TaskLookup.Candidate(id: "t4", slug: "docs", scopeID: "A", scopeSlug: "acme", isArchived: false)

    @Test func anIdIsExactWhateverTheSlugsSay() {
        #expect(TaskLookup.resolve("t1", among: [acmeArchived, betaLive], preferring: .live) == .found(acmeArchived))
    }

    @Test func aSlugSharedWithAnArchivedTaskGoesToTheLiveOne() {
        // The bug: creation order put the archived acme/health first, and archiving it again "succeeded".
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive, other], preferring: .live) == .found(betaLive))
        // Restore wants the opposite.
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive], preferring: .archived) == .found(acmeArchived))
    }

    @Test func aScopeSettlesIt() {
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive], preferring: .live, scopeID: "A") == .found(acmeArchived))
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive], preferring: .live, scopeID: "Z") == .none)
    }

    @Test func twoLiveNamesakesFallBackToTheCallersScopeThenRefuse() {
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive, gammaLive], preferring: .live, callerScopeID: "C") == .found(gammaLive))
        #expect(TaskLookup.resolve("health", among: [acmeArchived, betaLive, gammaLive], preferring: .live) == .ambiguous([betaLive, gammaLive]))
        // Nothing live at all: the archived ones are what is left to tell apart.
        let archivedToo = TaskLookup.Candidate(id: "t5", slug: "health", scopeID: "B", scopeSlug: "beta", isArchived: true)
        #expect(TaskLookup.resolve("health", among: [acmeArchived, archivedToo], preferring: .live) == .ambiguous([acmeArchived, archivedToo]))
    }

    @Test func nothingOfThatName() {
        #expect(TaskLookup.resolve("nope", among: [acmeArchived, betaLive], preferring: .live) == .none)
        #expect(TaskLookup.resolve("docs", among: [acmeArchived, other], preferring: .live) == .found(other))
    }
}
