import Foundation
import Testing
@testable import ScopeCore

/// Time on screen (spec §4.9): counted only while someone can be looking, cut and resumed around every pause, one
/// opening counted once however many runs it took.
@Suite struct ScreenTimeClockTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func anOpeningLooksAtIsOneSegment() {
        var clock = ScreenTimeClock()
        clock.open("inspector.delta", at: at(0))
        let segment = clock.close("inspector.delta", at: at(30))
        #expect(segment == .init(id: "inspector.delta", start: at(0), end: at(30), resumed: false))
        #expect(clock.close("inspector.delta", at: at(31)) == nil)
    }

    @Test func goingToTheBackgroundCutsTheRunAndComingBackStartsAnother() {
        var clock = ScreenTimeClock()
        clock.open("inspector.delta", at: at(0))
        let cut = clock.block(.inactive, at: at(60))
        #expect(cut == [.init(id: "inspector.delta", start: at(0), end: at(60), resumed: false)])
        clock.unblock(.inactive, at: at(3600))
        let last = clock.close("inspector.delta", at: at(3610))
        #expect(last == .init(id: "inspector.delta", start: at(3600), end: at(3610), resumed: true))
    }

    @Test func idlenessIsCutBackToTheLastInput() {
        var clock = ScreenTimeClock()
        clock.open("inspector.files", at: at(0))
        // Noticed at 200 s, last input at 50 s: the 150 s nobody was there do not count.
        let cut = clock.block(.idle, at: at(50))
        #expect(cut.map(\.duration) == [50])
        clock.unblock(.idle, at: at(200))
        #expect(clock.close("inspector.files", at: at(260))?.duration == 60)
    }

    @Test func idlenessNoticedBeforeAViewOpenedCountsNothingButTheOpening() {
        var clock = ScreenTimeClock()
        clock.open("sheet.inbox", at: at(100))
        let cut = clock.block(.idle, at: at(50))
        #expect(cut == [.init(id: "sheet.inbox", start: at(100), end: at(100), resumed: false)])
        clock.unblock(.idle, at: at(400))
        #expect(clock.close("sheet.inbox", at: at(400)) == nil)
    }

    @Test func aLockedSessionAndASleepingMacStackAndOnlyTheLastOneGoingResumes() {
        var clock = ScreenTimeClock()
        clock.open("viewer", at: at(0))
        #expect(clock.block(.locked, at: at(10)).map(\.duration) == [10])
        #expect(clock.block(.asleep, at: at(20)).isEmpty)
        clock.unblock(.locked, at: at(30))
        #expect(!clock.counting)
        #expect(clock.close("viewer", at: at(40)) == nil)
        clock.open("viewer", at: at(50))
        clock.unblock(.asleep, at: at(60))
        #expect(clock.close("viewer", at: at(70)) == .init(id: "viewer", start: at(60), end: at(70), resumed: false))
    }

    @Test func aViewOpenedWhilePausedStartsWhenTheClockResumes() {
        var clock = ScreenTimeClock(blockers: [.inactive])
        clock.open("inbox", at: at(0))
        clock.unblock(.inactive, at: at(100))
        #expect(clock.close("inbox", at: at(130)) == .init(id: "inbox", start: at(100), end: at(130), resumed: false))
    }

    @Test func aViewOpenedAndClosedWhilePausedIsStillAnOpening() {
        var clock = ScreenTimeClock(blockers: [.hidden])
        clock.open("inbox", at: at(0))
        #expect(clock.close("inbox", at: at(5)) == .init(id: "inbox", start: at(5), end: at(5), resumed: false))
    }

    @Test func closingEverythingAtQuitLogsEachOpenView() {
        var clock = ScreenTimeClock()
        clock.open("inspector.delta", at: at(0))
        clock.open("inspector", at: at(0))
        let segments = clock.closeAll(at: at(10))
        #expect(segments.map(\.id) == ["inspector", "inspector.delta"])
        #expect(segments.allSatisfy { $0.duration == 10 })
        #expect(clock.openIDs.isEmpty)
    }

    @Test func theSameBlockerTwiceIsOnce() {
        var clock = ScreenTimeClock()
        clock.open("viewer", at: at(0))
        #expect(clock.block(.inactive, at: at(10)).count == 1)
        #expect(clock.block(.inactive, at: at(20)).isEmpty)
        clock.unblock(.inactive, at: at(30))
        #expect(clock.counting)
    }
}
