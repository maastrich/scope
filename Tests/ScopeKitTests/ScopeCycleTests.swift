import Foundation
import Testing
@testable import ScopeCore

@Suite struct ScopeCycleTests {
    private let scopes = ["a", "b", "c", "d"]

    @Test func nextWrapsPastTheLast() {
        #expect(ScopeCycle.neighbour(of: "d", in: scopes, delta: 1) == "a")
    }

    @Test func previousWrapsPastTheFirst() {
        #expect(ScopeCycle.neighbour(of: "a", in: scopes, delta: -1) == "d")
    }

    @Test func aLoneScopeHasNoNeighbour() {
        #expect(ScopeCycle.neighbour(of: "a", in: ["a"], delta: 1) == nil)
        #expect(ScopeCycle.neighbour(of: "a", in: ["a"], delta: -1) == nil)
    }

    @Test func twoScopesAreEachOthersBothNeighbours() {
        #expect(ScopeCycle.neighbour(of: "a", in: ["a", "b"], delta: 1) == "b")
        #expect(ScopeCycle.neighbour(of: "a", in: ["a", "b"], delta: -1) == "b")
    }

    /// The point of a fixed ring: stepping forwards visits every scope once and comes home.
    @Test func stepsVisitEveryScopeAndComeBack() {
        var visited: [String] = []
        var current = "a"
        for _ in scopes.indices {
            current = ScopeCycle.neighbour(of: current, in: scopes, delta: 1) ?? current
            visited.append(current)
        }
        #expect(Set(visited) == Set(scopes))
        #expect(current == "a")
    }

    @Test func rotationStartsAtTheNextNeighbour() {
        #expect(ScopeCycle.rotated(scopes, after: "c") == ["d", "a", "b"])
        #expect(ScopeCycle.rotated(scopes, after: "a") == ["b", "c", "d"])
    }

    /// The first tile is where a swipe to the next goes, the last one where a swipe to the previous goes.
    @Test func rotationEndsAtThePreviousNeighbour() {
        let tiles = ScopeCycle.rotated(scopes, after: "c")
        #expect(tiles.first == ScopeCycle.neighbour(of: "c", in: scopes, delta: 1))
        #expect(tiles.last == ScopeCycle.neighbour(of: "c", in: scopes, delta: -1))
    }

    @Test func aStepForwardsIsForwardsEvenWhenItWraps() {
        #expect(ScopeCycle.isForward(from: "d", to: "a", in: scopes))
        #expect(ScopeCycle.isForward(from: "a", to: "b", in: scopes))
    }

    @Test func aStepBackwardsIsBackwardsEvenWhenItWraps() {
        #expect(!ScopeCycle.isForward(from: "a", to: "d", in: scopes))
        #expect(!ScopeCycle.isForward(from: "c", to: "b", in: scopes))
    }
}
