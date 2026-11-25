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

    // MARK: One query per pass

    @Test func aPassTakesAlongWhatIsCloseToDue() {
        var schedule = PullRequestRefreshSchedule(interval: 300)
        let c = TaskID.generate()
        schedule.sync([a, b, c], now: start)
        // Nothing due, nothing asked.
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: false)
        schedule.started(b, at: start.addingTimeInterval(200))
        schedule.succeeded(b, settled: false)
        schedule.started(c, at: start.addingTimeInterval(120))
        schedule.succeeded(c, settled: false)
        #expect(schedule.batch(at: start.addingTimeInterval(250)).isEmpty)
        // `a` is due: `c`, past half its wait, comes along; `b`, asked 100 s ago, does not.
        #expect(schedule.batch(at: start.addingTimeInterval(300)) == [a, c])
    }

    @Test func aTaskNeverAskedAboutJoinsTheFirstPass() {
        var schedule = PullRequestRefreshSchedule(interval: 300)
        schedule.sync([a, b], now: start)
        let first = [a, b].compactMap { id in schedule.nextDue(id).map { (id, $0) } }.min { $0.1 < $1.1 }!
        #expect(schedule.batch(at: first.1.addingTimeInterval(-1)).isEmpty)
        #expect(Set(schedule.batch(at: first.1)) == [a, b])
        #expect(schedule.batch(at: first.1).first == first.0)
    }

    @Test func aFleetAskedTogetherStaysTogether() {
        var schedule = PullRequestRefreshSchedule(interval: 300)
        let fleet = (0..<15).map { _ in TaskID.generate() }
        schedule.sync(fleet, now: start)
        var passes = 0
        var now = start
        while now < start.addingTimeInterval(3600) {
            let batch = schedule.batch(at: now)
            if !batch.isEmpty {
                passes += 1
                for id in batch {
                    schedule.started(id, at: now)
                    schedule.succeeded(id, settled: false)
                }
            }
            now.addTimeInterval(30)
        }
        // One query every five minutes for fifteen tasks, where each used to cost its own calls.
        #expect(passes <= 13, "\(passes) passes in an hour")
    }

    @Test func aSettledTaskIsLeftAloneUntilItIsPushed() {
        var schedule = PullRequestRefreshSchedule(interval: 300, settledInterval: 1800)
        schedule.sync([a, b], now: start)
        // Not settled, or never read: asked.
        #expect(!schedule.isUnchanged(a, heads: "refs/remotes/origin/feat 1111"))
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: true, heads: "refs/remotes/origin/feat 1111")
        schedule.started(b, at: start)
        schedule.succeeded(b, settled: false, heads: "refs/remotes/origin/fix 3333")
        #expect(schedule.isUnchanged(a, heads: "refs/remotes/origin/feat 1111"))
        #expect(!schedule.isUnchanged(b, heads: "refs/remotes/origin/fix 3333"))
        // A push, a branch gone from the remote, a new branch: asked again.
        #expect(!schedule.isUnchanged(a, heads: "refs/remotes/origin/feat 2222"))
        #expect(!schedule.isUnchanged(a, heads: ""))
        #expect(!schedule.isUnchanged(TaskID.generate(), heads: nil))
        // A settled task does not ride along with the others' passes.
        #expect(schedule.batch(at: start.addingTimeInterval(300)) == [b])
        #expect(schedule.batch(at: start.addingTimeInterval(1800)).contains(a))
    }

    @Test func aRestoredTaskIsAskedAgain() {
        var schedule = PullRequestRefreshSchedule()
        schedule.sync([a], now: start)
        schedule.started(a, at: start)
        schedule.succeeded(a, settled: true, heads: "h")
        schedule.reset(a, now: start.addingTimeInterval(60))
        #expect(!schedule.isUnchanged(a, heads: "h"))
        #expect(schedule.entries[a]?.settled == false && schedule.entries[a]?.lastAttempt == nil)
        schedule.reset(b, now: start)
        #expect(schedule.entries[b] == nil)
    }

    @Test func aPassThatNeverReachedGitHubLeavesItsTasksDue() {
        var schedule = PullRequestRefreshSchedule()
        schedule.sync([a], now: start)
        let later = start.addingTimeInterval(schedule.interval)
        schedule.started(a, at: later)
        #expect(schedule.due(at: later.addingTimeInterval(60)).isEmpty)
        schedule.held(a)
        #expect(schedule.due(at: later.addingTimeInterval(60)) == [a])
        #expect(schedule.entries[a]?.failures == 0)
    }
}
