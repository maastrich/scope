import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct PullRequestRefreshScheduleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let a = TaskID.generate()
    private let b = TaskID.generate()

    @Test func newTasksAreSpreadOverTheFirstInterval() {
        var schedule = PullRequestRefreshSchedule()
        schedule.sync([a, b], now: start)
        for id in [a, b] {
            guard let due = schedule.nextDue(id) else { Issue.record("not scheduled"); continue }
            #expect(due >= start && due < start.addingTimeInterval(schedule.interval))
        }
        #expect(Set(schedule.due(at: start.addingTimeInterval(schedule.interval))) == [a, b])
    }

    @Test func theStaggerIsStableAcrossLaunches() {
        #expect(PullRequestRefreshSchedule().stagger(a) == PullRequestRefreshSchedule().stagger(a))
    }

    @Test func aRefreshedTaskIsDueOneIntervalLater() {
        var schedule = PullRequestRefreshSchedule()
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: false)
        #expect(schedule.due(at: start.addingTimeInterval(schedule.interval - 1)).isEmpty)
        #expect(schedule.due(at: start.addingTimeInterval(schedule.interval)) == [a])
    }

    @Test func failuresBackOffUpToTheCap() {
        var schedule = PullRequestRefreshSchedule(interval: 300, maximumBackoff: 3600)
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.failed(a)
        #expect(schedule.nextDue(a) == start.addingTimeInterval(600))
        schedule.failed(a)
        #expect(schedule.nextDue(a) == start.addingTimeInterval(1200))
        for _ in 0..<10 { schedule.failed(a) }
        #expect(schedule.nextDue(a) == start.addingTimeInterval(3600))
        schedule.succeeded(a, settled: false)
        #expect(schedule.nextDue(a) == start.addingTimeInterval(300))
    }

    @Test func aMergedOrClosedPullRequestIsAskedLessOften() {
        var schedule = PullRequestRefreshSchedule(interval: 300, settledInterval: 1800)
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: true)
        #expect(schedule.nextDue(a) == start.addingTimeInterval(1800))
    }

    @Test func theLongestOverdueComesFirst() {
        var schedule = PullRequestRefreshSchedule(interval: 300)
        schedule.sync([a, b], now: start)
        schedule.started(a, at: start.addingTimeInterval(10))
        schedule.started(b, at: start)
        #expect(schedule.due(at: start.addingTimeInterval(1000)) == [b, a])
    }

    @Test func goneTasksLeaveTheSchedule() {
        var schedule = PullRequestRefreshSchedule()
        schedule.sync([a, b], now: start)
        schedule.sync([b], now: start)
        #expect(schedule.nextDue(a) == nil)
        #expect(schedule.nextDue(b) != nil)
    }

    // MARK: Freshness

    @Test func checksGoStalePastThreeIntervals() {
        let checked = start
        #expect(!PullRequestFreshness.isStale(checkedAt: checked, now: start.addingTimeInterval(900), interval: 300))
        #expect(PullRequestFreshness.isStale(checkedAt: checked, now: start.addingTimeInterval(901), interval: 300))
        #expect(PullRequestFreshness.isStale(checkedAt: nil, now: start))
    }

    @Test func ageReadsInTheLargestWholeUnit() {
        #expect(PullRequestFreshness.age(since: start, now: start.addingTimeInterval(20)) == "just now")
        #expect(PullRequestFreshness.age(since: start, now: start.addingTimeInterval(4 * 60 + 30)) == "4 min ago")
        #expect(PullRequestFreshness.age(since: start, now: start.addingTimeInterval(2 * 3600 + 10)) == "2 h ago")
        #expect(PullRequestFreshness.age(since: start, now: start.addingTimeInterval(3 * 86_400)) == "3 d ago")
        #expect(PullRequestFreshness.age(since: start, now: start.addingTimeInterval(-5)) == "just now")
    }

    // MARK: Archive on merge (the guards themselves: `MergedTaskArchiveTests`)

    private func merged(_ states: [String?], threads: [ThreadState] = [], enabled: Bool = true,
                        kept: Bool = false) -> MergedTaskArchive {
        let mergedAt = Date(timeIntervalSince1970: 1_000)
        return MergedTaskArchive.decide(.init(
            pullRequests: states.map { .init(state: $0, mergedAt: $0 == "merged" ? mergedAt : nil) },
            threads: threads.map { .init(state: $0) }, enabled: enabled, keptOpenAfterMerge: kept))
    }

    @Test func aMergedPullRequestArchivesAQuietTask() {
        for threads in [[], [ThreadState.idle], [.done], [.exited]] {
            #expect(merged(["merged"], threads: threads) == .archive)
        }
    }

    @Test func aRunningThreadPostponesTheArchive() {
        #expect(merged(["merged"], threads: [.idle, .running]) == .hold(.threadBusy))
    }

    @Test func nothingButAMergeArchives() {
        for state in [nil, "open", "closed"] {
            #expect(merged([state]) == .keep)
        }
    }

    @Test func thePreferenceAndARestoreKeepTheTask() {
        #expect(merged(["merged"], enabled: false) == .keep)
        #expect(merged(["merged"], kept: true) == .keep)
    }

    @Test func preferencesDefaultToArchivingMergedTasksAndThreeIdleDays() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.archiveMergedTasks)
        #expect(preferences.dormantAfterDays == 3)
        let negative = try JSONDecoder().decode(Preferences.self, from: Data(#"{"dormantAfterDays": -2}"#.utf8))
        #expect(negative.dormantAfterDays == 0)
    }

    @Test func aTaskWithSeveralPullRequestsArchivesOnceNoneIsOpen() {
        // One merged, one still open: the task stays. Once the second lands — or is dropped — it goes.
        #expect(merged(["merged", "open"]) == .keep)
        #expect(merged(["merged", nil]) == .keep)
        #expect(merged(["merged", "merged"]) == .archive)
        #expect(merged(["merged", "closed"]) == .archive)
        #expect(merged(["closed", "closed"]) == .keep)
        #expect(merged([]) == .keep)
        #expect(merged(["merged", "merged"], threads: [.running]) == .hold(.threadBusy))
    }
}
