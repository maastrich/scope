import Foundation
import ScopeCore
import Testing

/// The terminal's scroll marker: there when history is, sized and placed from SwiftTerm's own numbers.
@Suite struct TerminalScrollMarkerTests {
    @Test func nothingToScrollDrawsNothing() {
        #expect(TerminalScrollMarker.knob(trackLength: 600, position: 1, proportion: 0.5, canScroll: false) == nil)
        #expect(TerminalScrollMarker.knob(trackLength: 600, position: 0, proportion: 1, canScroll: true) == nil)
        #expect(TerminalScrollMarker.knob(trackLength: 0, position: 0, proportion: 0.5, canScroll: true) == nil)
    }

    @Test func theKnobIsTheVisibleShareOfTheHistory() throws {
        let knob = try #require(TerminalScrollMarker.knob(trackLength: 600, position: 0, proportion: 0.25, canScroll: true))
        #expect(knob.length == 150)
        #expect(knob.offset == 0)
    }

    /// Following the output — the usual case — puts the knob at the bottom of the track.
    @Test func atTheNewestLineTheKnobSitsAtTheBottom() throws {
        let knob = try #require(TerminalScrollMarker.knob(trackLength: 600, position: 1, proportion: 0.25, canScroll: true))
        #expect(knob.offset + knob.length == 600)
    }

    @Test func halfwayIsHalfway() throws {
        let knob = try #require(TerminalScrollMarker.knob(trackLength: 600, position: 0.5, proportion: 0.25, canScroll: true))
        #expect(knob.offset == 225)
    }

    @Test func aLongHistoryStillGetsAKnobYouCanSee() throws {
        let knob = try #require(TerminalScrollMarker.knob(trackLength: 600, position: 1, proportion: 0.001, canScroll: true))
        #expect(knob.length == TerminalScrollMarker.minimumLength)
        #expect(knob.offset + knob.length == 600)
    }

    @Test func aPositionOutOfRangeIsClamped() throws {
        let above = try #require(TerminalScrollMarker.knob(trackLength: 600, position: -2, proportion: 0.5, canScroll: true))
        let below = try #require(TerminalScrollMarker.knob(trackLength: 600, position: 3, proportion: 0.5, canScroll: true))
        #expect(above.offset == 0)
        #expect(below.offset == 300)
    }
}
