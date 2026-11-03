import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct SidebarScrollHoldTests {
    @Test func withNoScrollEveryRowGoesWhereItsStatePutsIt() {
        let hold = SidebarScrollHold<String>()
        #expect(!hold.isHolding)
        #expect(hold.group(of: "a", live: .working) == .working)
        #expect(hold.heldGroup(of: "a") == nil)
    }

    @Test func duringAScrollARowKeepsTheGroupItHadWhenTheScrollBegan() {
        var hold = SidebarScrollHold<String>()
        hold.begin(["a": .quiet, "b": .working])
        // "a" starts working and "b" finishes while the fingers are on the trackpad: neither moves.
        #expect(hold.group(of: "a", live: .working) == .quiet)
        #expect(hold.group(of: "b", live: .finished) == .working)
        #expect(hold.heldGroup(of: "a") == .quiet)
    }

    @Test func aRowThatAppearsDuringTheScrollGoesWhereItBelongs() {
        var hold = SidebarScrollHold<String>()
        hold.begin(["a": .quiet])
        #expect(hold.group(of: "new", live: .needsYou) == .needsYou)
        #expect(hold.heldGroup(of: "new") == nil)
    }

    @Test func theRowsSettleOnceTheScrollEnds() {
        var hold = SidebarScrollHold<String>()
        hold.begin(["a": .quiet])
        hold.end()
        #expect(!hold.isHolding)
        #expect(hold.group(of: "a", live: .working) == .working)
    }

    @Test func aSecondBeginBeforeTheEndKeepsTheFirstSnapshot() {
        var hold = SidebarScrollHold<String>()
        hold.begin(["a": .quiet])
        hold.begin(["a": .working])
        #expect(hold.group(of: "a", live: .working) == .quiet)
    }

    @Test func aHeldCompactRowKeepsTheHeightItHad() {
        // Quiet when the scroll began, working now: still one line.
        #expect(!SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .running, held: .quiet))
        // Working when the scroll began, done now: still two lines.
        #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .done, held: .working))
        #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .clean, held: .needsYou))
    }

    @Test func withNothingHeldARowFollowsItsStatus() {
        #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .running, held: nil))
        #expect(!SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .clean, held: nil))
    }

    @Test func aDetailedRowIsTwoLinesWhateverIsHeld() {
        #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .detailed, status: .clean, held: .quiet))
    }

    @Test func aHeldRowIsAsTallAsItsHeldGroupSays() {
        for group in SidebarGroup.allCases {
            let busy = group == .needsYou || group == .working
            #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: .clean, held: group) == busy, "\(group)")
        }
    }
}
