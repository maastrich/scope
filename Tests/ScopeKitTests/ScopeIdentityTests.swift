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
        #expect(scope.icon == nil && scope.tint == nil && scope.logo == nil)
    }

    @Test func identityRoundTripsAndAnUnknownTintIsDropped() throws {
        let scope = ScopeDeclaration(path: "/work/acme", slug: "acme", icon: "A", tint: .sky, logo: "acme.png")
        let decoded = try JSONDecoder().decode(ScopeDeclaration.self, from: JSONEncoder().encode(scope))
        #expect(decoded.icon == "A" && decoded.tint == .sky && decoded.logo == "acme.png")
        let json = #"{"id":"0b0e7c5e-3f0a-4a53-9d5f-0d6a3b7f1c11","path":"/work/acme","slug":"acme","tint":"neon"}"#
        #expect(try JSONDecoder().decode(ScopeDeclaration.self, from: Data(json.utf8)).tint == nil)
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

    @Test func tilesByImportanceKeepDeclaredOrderAmongEquals() {
        let items: [(id: String, activity: ScopeActivity)] = [
            ("a", .quiet), ("b", .working), ("c", .quiet), ("d", .waiting), ("e", .missing), ("f", .working),
        ]
        #expect(ScopeTileOrder.byImportance.arranged(items) == ["d", "b", "f", "a", "c", "e"])
        #expect(ScopeTileOrder.declared.arranged(items) == ["a", "b", "c", "d", "e", "f"])
    }
}
