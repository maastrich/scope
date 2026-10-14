import Foundation
import Testing
@testable import ScopeCore

@Suite struct ScopeIdentityTests {
    @Test func tintIsStableForASlugAndCoversTheSet() {
        #expect(ScopeTint.derived(from: "maastrich") == ScopeTint.derived(from: "maastrich"))
        let seen = Set((0..<200).map { ScopeTint.derived(from: "scope-\($0)") })
        #expect(seen.count == ScopeTint.allCases.count)
    }

    @Test func monogramSkipsTheAtSignAndPrefersTheChosenIcon() {
        var scope = ScopeDeclaration(path: "/work/@maastrich", slug: "maastrich")
        #expect(scope.monogram == "M")
        scope.icon = " 🧪 "
        #expect(scope.monogram == "🧪")
        scope.icon = "  "
        #expect(scope.monogram == "M")
    }

    @Test func aChosenTintWinsOverTheDerivedOne() {
        var scope = ScopeDeclaration(path: "/work/acme", slug: "acme")
        #expect(scope.resolvedTint == .derived(from: "acme"))
        scope.tint = .clay
        #expect(scope.resolvedTint == .clay)
    }

    @Test func aDeclarationWithoutIdentityFieldsStillDecodes() throws {
        let json = #"{"id":"0b0e7c5e-3f0a-4a53-9d5f-0d6a3b7f1c11","path":"/work/acme","slug":"acme"}"#
        let scope = try JSONDecoder().decode(ScopeDeclaration.self, from: Data(json.utf8))
        #expect(scope.icon == nil && scope.tint == nil && scope.logo == nil && scope.logoDark == nil && scope.context == nil)
    }

    @Test func identityRoundTripsAndAnUnknownTintIsDropped() throws {
        let scope = ScopeDeclaration(path: "/work/acme", slug: "acme", icon: "A", tint: .sky, logo: "acme.png",
                                     logoDark: "acme-dark.png", context: "Billing lives in api.")
        let decoded = try JSONDecoder().decode(ScopeDeclaration.self, from: JSONEncoder().encode(scope))
        #expect(decoded.icon == "A" && decoded.tint == .sky && decoded.logo == "acme.png")
        #expect(decoded.logoDark == "acme-dark.png" && decoded.context == "Billing lives in api.")
        let json = #"{"id":"0b0e7c5e-3f0a-4a53-9d5f-0d6a3b7f1c11","path":"/work/acme","slug":"acme","tint":"neon"}"#
        #expect(try JSONDecoder().decode(ScopeDeclaration.self, from: Data(json.utf8)).tint == nil)
    }

    @Test func theDarkImageOnlyReplacesTheImageInTheDarkAppearance() {
        var scope = ScopeDeclaration(path: "/work/acme", slug: "acme", logo: "acme.png")
        #expect(scope.logo(dark: false) == "acme.png" && scope.logo(dark: true) == "acme.png")
        scope.logoDark = "acme-dark.png"
        #expect(scope.logo(dark: false) == "acme.png" && scope.logo(dark: true) == "acme-dark.png")
        // A dark image alone leaves the light appearance on the letter.
        scope.logo = nil
        #expect(scope.logo(dark: false) == nil && scope.logo(dark: true) == "acme-dark.png")
    }

    @Test func activityIsTheMostPressingThread() {
        #expect(ScopeActivity(threads: []) == .quiet)
        #expect(ScopeActivity(threads: [.idle, .exited]) == .quiet)
        #expect(ScopeActivity(threads: [.idle, .running]) == .working)
        #expect(ScopeActivity(threads: [.running, .done]) == .unread)
        #expect(ScopeActivity(threads: [.done, .failed, .running]) == .failed)
        #expect(ScopeActivity(threads: [.failed, .waiting(reason: .input)]) == .waiting)
        #expect(ScopeActivity(threads: [.waiting(reason: .permission)], missing: true) == .missing)
    }

    private let ring: [(id: String, activity: ScopeActivity)] = [
        ("a", .quiet), ("b", .working), ("c", .quiet), ("d", .waiting), ("e", .missing), ("f", .working),
    ]

    @Test func everyTileFitsInRingOrder() {
        for order in ScopeTileOrder.allCases {
            let split = order.split(ring, visible: 6)
            #expect(split.shown == ["a", "b", "c", "d", "e", "f"])
            #expect(split.hidden.isEmpty)
        }
    }

    /// The urgent ones survive the counter, but they are drawn where they sit in the ring, not first.
    @Test func importancePicksTheSurvivorsNotTheirPlace() {
        let split = ScopeTileOrder.byImportance.split(ring, visible: 4)
        #expect(split.shown == ["a", "b", "d", "f"])
        #expect(split.hidden == ["c", "e"])
    }

    @Test func declaredKeepsTheNearestScopes() {
        let split = ScopeTileOrder.declared.split(ring, visible: 4)
        // `e` is two steps back, `c` three steps on.
        #expect(split.shown == ["a", "b", "e", "f"])
        #expect(split.hidden == ["c", "d"])
    }

    /// The first and last tiles are where a swipe goes, so they outrank any urgency elsewhere.
    @Test func swipeDestinationsKeepTheirTiles() {
        #expect(ScopeTileOrder.byImportance.split(ring, visible: 2).shown == ["a", "f"])
        #expect(ScopeTileOrder.byImportance.split(ring, visible: 1).shown == ["a"])
        #expect(ScopeTileOrder.byImportance.split(ring, visible: 0).shown.isEmpty)
        #expect(ScopeTileOrder.byImportance.split(ring, visible: 0).hidden.count == 6)
    }

    @Test func importanceTiesGoToTheNearerScope() {
        let quiet = ring.map { (id: $0.id, activity: ScopeActivity.quiet) }
        #expect(ScopeTileOrder.byImportance.split(quiet, visible: 4).shown == ["a", "b", "e", "f"])
    }
}
