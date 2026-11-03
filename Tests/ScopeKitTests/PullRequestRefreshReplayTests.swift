import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// The two stretches of the event journal of 27/10–03/11 that made the pull request refresh worth slowing down,
/// replayed through the schedule and the gate as `AppModel+PullRequestRefresh` and the inspector drive them.
///
/// - The idle night of 02/11 17:00 → 03/11 07:00 UTC: 3,407 `gh` calls in 14 h (≈ 245 an hour), nobody at the Mac.
/// - The outage of 28/10 22:00 → 29/10 15:00: 2,300 calls in 17 h, 2,216 of them failed in about 0.1 s.
///
/// The fleet is the one open that night, from the task records: fourteen tasks with an open pull request or unpushed
/// work (two of them on two branches), four whose pull request was merged or closed and which also hold a link no
/// branch names (the 2 `pr view` an hour), and the inspector showing one of the open ones.
@Suite struct PullRequestRefreshReplayTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct FleetTask {
        let id = TaskID.generate()
        /// Branches its sandboxes are on or visited: one `gh pr list --head` each.
        var branches: Int
        /// Links no branch names: one `gh pr view` each.
        var orphanLinks = 0
        var settled = false
        var hasLinks: Bool { settled || orphanLinks > 0 }
        var calls: Int { branches + orphanLinks }
    }

    static func nightFleet() -> (tasks: [FleetTask], onScreen: TaskID) {
        var tasks = (0..<12).map { _ in FleetTask(branches: 1) } + (0..<2).map { _ in FleetTask(branches: 2) }
        tasks += (0..<4).map { _ in FleetTask(branches: 1, orphanLinks: 1, settled: true) }
        return (tasks, tasks[0].id)
    }

    enum Network { case up, failing(GhFailure) }

    /// Calls `gh` would have taken over `hours`, the background pass ticking every 30 s and the inspector every 60 s.
    ///
    /// `legacy` replays the code before this change: the inspector refreshed every minute whatever happened, a failed
    /// branch lookup was skipped silently (only a failed `pr view` of a link counted against the task), every lookup of
    /// the task ran anyway, and nothing looked at who was there or whether the last call had failed.
    func replay(hours: Double, network: Network, attention: PullRequestRefreshSchedule.Attention,
                pathMonitorSeesIt: Bool = false, legacy: Bool) -> Int {
        let (fleet, onScreen) = Self.nightFleet()
        var schedule = PullRequestRefreshSchedule()
        schedule.attention = legacy ? .active : attention
        var gate = PullRequestRefreshGate()
        if pathMonitorSeesIt, !legacy { gate.setOnline(false, at: start) }
        schedule.sync(fleet.map(\.id), now: start)
        let byID = Dictionary(uniqueKeysWithValues: fleet.map { ($0.id, $0) })
        var calls = 0

        /// One task's refresh: what it costs and what the schedule and the gate learn from it.
        func refresh(_ task: FleetTask, at now: Date) {
            schedule.started(task.id, at: now)
            switch network {
            case .up:
                calls += task.calls
                schedule.succeeded(task.id, settled: task.settled)
                gate.succeeded()
            case .failing(let cause):
                if legacy {
                    calls += task.calls
                    if task.hasLinks { schedule.failed(task.id) } else { schedule.succeeded(task.id, settled: false) }
                } else {
                    // The first global failure ends the task's refresh: its other lookups would fail the same way.
                    calls += cause.isGlobal ? 1 : task.calls
                    schedule.failed(task.id)
                    gate.failed(cause, at: now)
                }
            }
        }

        var lastForeground = Date.distantPast
        var now = start
        let end = start.addingTimeInterval(hours * 3600)
        while now < end {
            if legacy || gate.allows(at: now) {
                for id in schedule.due(at: now) {
                    // The pass stops handing out tasks once the gate closes behind a global failure.
                    guard legacy || gate.allows(at: now), let task = byID[id] else { break }
                    refresh(task, at: now)
                }
            }
            if now.timeIntervalSince(lastForeground) >= PullRequestRefreshSchedule.foregroundInterval {
                lastForeground = now
                if legacy {
                    calls += byID[onScreen]!.calls
                } else if gate.allows(at: now), schedule.foregroundDue(onScreen, at: now) {
                    refresh(byID[onScreen]!, at: now)
                }
            }
            now.addTimeInterval(30)
        }
        return calls
    }

    @Test func theIdleNightCostsATenthOfItsCalls() {
        let measured = 3_407
        let before = replay(hours: 14, network: .up, attention: .away, legacy: true)
        // The model stands for that night: within a fifth of what the journal counted.
        #expect(abs(before - measured) < measured / 5, "legacy replay \(before) vs measured \(measured)")
        let after = replay(hours: 14, network: .up, attention: .away, legacy: false)
        #expect(after * 10 <= measured, "\(after) calls after, \(measured) measured")
        #expect(after * 10 <= before, "\(after) calls after, \(before) before")
        print("idle night: measured \(measured), legacy replay \(before), after \(after)")
    }

    @Test func aSeventeenHourOutageCostsATenthOfItsCalls() {
        let measured = 2_300
        // The worst case: the network monitor saw nothing (GitHub unreachable behind a working Wi-Fi), and someone
        // was at the Mac the whole time.
        let after = replay(hours: 17, network: .failing(.offline), attention: .active, legacy: false)
        #expect(after * 10 <= measured, "\(after) calls after, \(measured) measured")
        let before = replay(hours: 17, network: .failing(.offline), attention: .active, legacy: true)
        #expect(after * 10 <= before, "\(after) calls after, \(before) before")
        print("outage: measured \(measured), legacy replay \(before), after \(after)")
        // When the monitor does see it, nothing goes out at all.
        #expect(replay(hours: 17, network: .failing(.offline), attention: .active, pathMonitorSeesIt: true, legacy: false) == 0)
    }

    @Test func anActiveDayKeepsItsCadence() {
        // Someone at the Mac, everything answering: the change must not slow down what they look at.
        let before = replay(hours: 1, network: .up, attention: .active, legacy: true)
        let after = replay(hours: 1, network: .up, attention: .active, legacy: false)
        #expect(after <= before)
        #expect(after * 10 >= before * 9, "\(after) after vs \(before) before")
    }
}

@Suite struct PullRequestRefreshGateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func nothingGoesOutOfflineOrAsleep() {
        var gate = PullRequestRefreshGate()
        #expect(gate.allows(at: start))
        gate.setOnline(false, at: start)
        #expect(!gate.allows(at: start.addingTimeInterval(3600)))
        #expect(gate.nextAllowed() == nil)
        gate.setOnline(true, at: start.addingTimeInterval(100))
        gate.setAsleep(true, at: start.addingTimeInterval(200))
        #expect(!gate.allows(at: start.addingTimeInterval(300)))
    }

    @Test func aWakeOrAReconnectWaitsAMoment() {
        var gate = PullRequestRefreshGate()
        gate.setAsleep(true, at: start)
        gate.setAsleep(false, at: start.addingTimeInterval(1000))
        #expect(!gate.allows(at: start.addingTimeInterval(1000 + PullRequestRefreshGate.resumeGrace - 1)))
        #expect(gate.allows(at: start.addingTimeInterval(1000 + PullRequestRefreshGate.resumeGrace)))
    }

    @Test func globalFailuresBackOffExponentiallyUpToTheCap() {
        var gate = PullRequestRefreshGate()
        var waits: [TimeInterval] = []
        var now = start
        for _ in 0..<9 {
            gate.failed(.offline, at: now)
            let next = gate.nextAllowed()!
            waits.append(next.timeIntervalSince(now))
            now = next
        }
        #expect(waits == [60, 120, 240, 480, 960, 1920, 3600, 3600, 3600])
        gate.succeeded()
        #expect(gate.allows(at: now))
    }

    @Test func aRateLimitWaitsAtLeastFifteenMinutes() {
        var gate = PullRequestRefreshGate()
        gate.failed(.rateLimit, at: start)
        #expect(gate.nextAllowed() == start.addingTimeInterval(PullRequestRefreshGate.rateLimitBackoff))
    }

    @Test func aFailureOfOneTaskHoldsNothingElseBack() {
        var gate = PullRequestRefreshGate()
        gate.failed(.missingCheckout, at: start)
        gate.failed(.notFound, at: start)
        #expect(gate.allows(at: start))
    }
}

@Suite struct PullRequestRefreshAttentionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let a = TaskID.generate()

    private func attempted(_ attention: PullRequestRefreshSchedule.Attention, settled: Bool = false,
                           busy: Bool = false, eager: Bool = false) -> TimeInterval? {
        var schedule = PullRequestRefreshSchedule()
        schedule.attention = attention
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: settled)
        schedule.setBusy(a, busy)
        schedule.setEager(a, eager)
        // Whole seconds: `Date` arithmetic leaves a few ulps behind.
        return schedule.nextDue(a).map { $0.timeIntervalSince(start).rounded() }
    }

    @Test func intervalsStretchWhenNobodyLooks() {
        #expect(attempted(.active) == 300)
        #expect(attempted(.background) == 600)
        #expect(attempted(.away) == 3600)
        #expect(attempted(.active, settled: true) == 1800)
        #expect(attempted(.away, settled: true) == 21_600)
    }

    @Test func aBusyTaskKeepsTheActiveCadence() {
        #expect(attempted(.away, busy: true) == 300)
        #expect(attempted(.away, busy: true, eager: true) == 90)
    }

    @Test func anEagerTaskIsNotEagerWhileEveryoneIsAway() {
        #expect(attempted(.active, eager: true) == 90)
        #expect(attempted(.background, eager: true) == 180)
        #expect(attempted(.away, eager: true) == 3600)
    }

    @Test func comingBackMakesAStretchedTaskDueAtOnce() {
        var schedule = PullRequestRefreshSchedule()
        schedule.attention = .away
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: false)
        let later = start.addingTimeInterval(400)
        #expect(schedule.due(at: later).isEmpty)
        schedule.attention = .active
        #expect(schedule.due(at: later) == [a])
    }

    @Test func attentionFollowsTheSystem() {
        typealias A = PullRequestRefreshSchedule.Attention
        #expect(A.resolve(frontmost: true, locked: false, displaysAsleep: false, idleSeconds: 30) == .active)
        #expect(A.resolve(frontmost: false, locked: false, displaysAsleep: false, idleSeconds: 30) == .background)
        #expect(A.resolve(frontmost: true, locked: false, displaysAsleep: false, idleSeconds: A.awayAfter) == .away)
        #expect(A.resolve(frontmost: true, locked: true, displaysAsleep: false, idleSeconds: 0) == .away)
        #expect(A.resolve(frontmost: false, locked: false, displaysAsleep: true, idleSeconds: 0) == .away)
    }

    @Test func theInspectorRefreshesOnlyWhileScopeIsInFrontAndBacksOff() {
        var schedule = PullRequestRefreshSchedule()
        #expect(!schedule.foregroundDue(a, at: start))
        schedule.include(a, now: start)
        #expect(schedule.foregroundDue(a, at: start))
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: false)
        #expect(!schedule.foregroundDue(a, at: start.addingTimeInterval(59)))
        #expect(schedule.foregroundDue(a, at: start.addingTimeInterval(60)))
        schedule.failed(a)
        schedule.failed(a)
        #expect(!schedule.foregroundDue(a, at: start.addingTimeInterval(239)))
        #expect(schedule.foregroundDue(a, at: start.addingTimeInterval(240)))
        schedule.attention = .background
        #expect(!schedule.foregroundDue(a, at: start.addingTimeInterval(3600)))
    }
}
