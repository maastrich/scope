import Foundation
import Testing
@testable import ScopeCore

@Suite struct PageSwipeTests {
    private func swipe(previous: Bool = true, next: Bool = true) -> PageSwipe {
        PageSwipe(width: 300, hasPrevious: previous, hasNext: next)
    }

    /// Slow, even steps: 4 pt every 1/60 s is 240 pt/s, under the flick speed.
    private func drag(_ swipe: inout PageSwipe, by distance: Double, step: Double = 4, from start: TimeInterval = 0) -> TimeInterval {
        var time = start
        var moved = 0.0
        while abs(moved) < abs(distance) {
            let dx = distance < 0 ? -step : step
            time += 1.0 / 60
            swipe.move(dx: dx, dy: 0, at: time)
            moved += dx
        }
        return time
    }

    @Test func axisWaitsForTheLockDistance() {
        var s = swipe()
        #expect(s.move(dx: -3, dy: 0, at: 0) == .undecided)
        #expect(s.offset == 0)
        #expect(s.move(dx: -6, dy: 1, at: 0.01) == .horizontal)
        // The points spent deciding are kept.
        #expect(s.offset == -9)
    }

    @Test func verticalStartStaysVertical() {
        var s = swipe()
        #expect(s.move(dx: 2, dy: 9, at: 0) == .vertical)
        #expect(s.move(dx: -200, dy: 0, at: 0.02) == .vertical)
        #expect(s.offset == 0)
        #expect(s.end(at: 0.03) == .stay)
    }

    @Test func diagonalStartIsVertical() {
        var s = swipe()
        #expect(s.move(dx: 7, dy: 6, at: 0) == .vertical)
    }

    @Test func offsetFollowsTheFingersUpToAPage() {
        var s = swipe()
        s.move(dx: -10, dy: 0, at: 0)
        s.move(dx: -100, dy: 0, at: 0.01)
        #expect(s.offset == -110)
        s.move(dx: -500, dy: 0, at: 0.02)
        #expect(s.offset == -300)
    }

    @Test func noNeighbourRubberBands() {
        var s = swipe(next: false)
        s.move(dx: -10, dy: 0, at: 0)
        s.move(dx: -290, dy: 0, at: 0.01)
        #expect(s.offset < 0)
        #expect(s.offset > -300 * 0.55)
        #expect(PageSwipe.rubberBand(1000, dimension: 300, stiffness: 0.55) < 300)
    }

    @Test func slowDragPastTheFractionTurns() {
        var s = swipe()
        let time = drag(&s, by: -120)
        #expect(s.end(at: time) == .turn(1))
    }

    @Test func slowDragShortOfTheFractionStays() {
        var s = swipe()
        let time = drag(&s, by: 80)
        #expect(s.end(at: time) == .stay)
    }

    @Test func rightwardDragGoesToThePrevious() {
        var s = swipe()
        let time = drag(&s, by: 120)
        #expect(s.end(at: time) == .turn(-1))
    }

    @Test func shortFlickTurns() {
        var s = swipe()
        s.move(dx: -10, dy: 0, at: 0)
        s.move(dx: -15, dy: 0, at: 0.016)
        s.move(dx: -15, dy: 0, at: 0.032)
        #expect(s.velocity(at: 0.04) < -500)
        #expect(s.end(at: 0.04) == .turn(1))
    }

    @Test func flickBackCancels() {
        var s = swipe()
        var time = drag(&s, by: -200)
        for _ in 0..<3 {
            time += 1.0 / 60
            s.move(dx: 15, dy: 0, at: time)
        }
        #expect(s.end(at: time) == .stay)
    }

    @Test func fingersThatStoppedHaveNoVelocity() {
        var s = swipe()
        s.move(dx: -10, dy: 0, at: 0)
        s.move(dx: -20, dy: 0, at: 0.016)
        #expect(s.velocity(at: 0.5) == 0)
        #expect(s.end(at: 0.5) == .stay)
    }

    @Test func nothingToTurnToStays() {
        var s = swipe(next: false)
        let time = drag(&s, by: -200)
        #expect(s.end(at: time) == .stay)
    }
}
