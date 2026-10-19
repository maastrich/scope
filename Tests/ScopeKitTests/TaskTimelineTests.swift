import Foundation
import ScopeAdapters
import ScopeCore
import ScopeGit
import Testing
@testable import ScopeTasks

/// `TaskTimeline` (lanes, waits, ticks, totals), `TimelineScale` (folding quiet hours), `TaskTimelineLog` and its
/// store, and the totals a closed task leaves in the history.
@Suite struct TaskTimelineTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func turn(_ start: Double?, _ end: Double, _ outcome: ThreadActivity.Turn.Outcome = .ended,
                     said: String? = nil) -> ThreadActivity.Turn {
        ThreadActivity.Turn(startedAt: start.map(at), endedAt: at(end), outcome: outcome, tools: 3, said: said)
    }

    static func lane(_ id: String, created: Double = 0, closed: Double? = nil, _ turns: [ThreadActivity.Turn],
                     open: Double? = nil, state: ThreadState? = .idle) -> TimelineLaneSource {
        TimelineLaneSource(threadID: id, title: "t-\(id)", driverID: "claude-code", createdAt: at(created),
                           closedAt: closed.map(at), turns: turns, openTurnSince: open.map(at), state: closed == nil ? state : nil)
    }

    static func build(_ lanes: [TimelineLaneSource], now: Double = 120, archived: Double? = nil,
                      pr: (number: Int, openedAt: Date?, mergedAt: Date?, closedAt: Date?)? = nil,
                      checks: [TaskCheckMark] = []) -> TaskTimeline {
        TaskTimeline.build(createdAt: t0, archivedAt: archived.map(at), now: at(now), pullRequests: pr.map { [$0] } ?? [], checks: checks, lanes: lanes)
    }

    static func kinds(_ lane: TaskTimeline.Lane) -> [TaskTimeline.Span.Kind] { lane.spans.map(\.kind) }

    // MARK: Lanes

    @Test func turnsAreWorkAndTheGapsAfterAQuestionOrAResultAreWaits() {
        let timeline = Self.build([Self.lane("a", [
            Self.turn(1, 10, .inputRequested),
            Self.turn(15, 30, .permissionRequested),
            Self.turn(32, 40, .ended),
            Self.turn(60, 70, .interrupted),
            Self.turn(80, 90, .ended),
        ])])
        let spans = timeline.lanes[0].spans
        let waits = spans.filter(\.kind.isWait)
        #expect(waits.map(\.kind) == [.waitingAnswer, .waitingPermission, .unreadResult])
        #expect(waits.map { $0.duration / 60 } == [5, 2, 20], "a result waits from its end to the next prompt")
        #expect(spans.filter { $0.kind == .working }.count == 5)
        #expect(!waits.contains { $0.start == Self.at(70) }, "an interrupted turn waits on nobody")
        #expect(!waits.contains { $0.start == Self.at(90) }, "a result already read stops counting at its end")
    }

    @Test func aLiveWaitKeepsCountingUntilNowWhileTheThreadStillShowsIt() {
        let asking = Self.build([Self.lane("a", [Self.turn(0, 10, .inputRequested)], state: .waiting(reason: .input))], now: 40)
        #expect(asking.lanes[0].spans.first { $0.kind == .waitingAnswer }?.end == Self.at(40))
        #expect(asking.totals.waiting == 30 * 60)

        let unread = Self.build([Self.lane("a", [Self.turn(0, 10, .failed)], state: .failed)], now: 40)
        #expect(unread.lanes[0].spans.first?.kind == .unreadResult)
        #expect(unread.lanes[0].spans.contains { $0.failed })

        let answeredElsewhere = Self.build([Self.lane("a", [Self.turn(0, 10, .permissionRequested)], state: .idle)], now: 40)
        #expect(answeredElsewhere.totals.waiting == 0, "the thread no longer shows the request")
    }

    @Test func aClosedThreadsLastQuestionWaitsUntilItWasClosedAndItsResultDoesNot() {
        let asked = Self.build([Self.lane("a", closed: 50, [Self.turn(0, 10, .inputRequested)])], now: 100)
        #expect(asked.totals.waiting == 40 * 60)
        let finished = Self.build([Self.lane("a", closed: 50, [Self.turn(0, 10, .ended)])], now: 100)
        #expect(finished.totals.waiting == 0)
    }

    @Test func theTurnInProgressRunsToNowAndAfterAWaitEndsIt() {
        let timeline = Self.build([Self.lane("a", [Self.turn(0, 10, .permissionRequested)], open: 14, state: .running)], now: 30)
        let spans = timeline.lanes[0].spans
        #expect(spans.first { $0.kind == .waitingPermission }?.end == Self.at(14))
        let running = spans.first { $0.running }
        #expect(running?.start == Self.at(14))
        #expect(running?.end == Self.at(30))
        #expect(timeline.totals.agent == (10 + 16) * 60)
    }

    @Test func aTurnWithNoKnownStartIsAMomentNotAStretch() {
        let timeline = Self.build([Self.lane("a", [Self.turn(nil, 10)])])
        let work = timeline.lanes[0].spans.first { $0.kind == .working }
        #expect(work?.start == Self.at(10))
        #expect(work?.duration == 0)
    }

    @Test func everythingIsClippedToTheTaskAndLanesComeInOrderOfCreation() {
        let timeline = Self.build([
            Self.lane("late", created: 30, [Self.turn(40, 50)]),
            Self.lane("early", created: -60, [Self.turn(-30, 5), Self.turn(100, 200)]),
        ], now: 150)
        #expect(timeline.lanes.map(\.id) == ["early", "late"])
        let early = timeline.lanes[0].spans.filter { $0.kind == .working }
        #expect(early.first?.start == Self.t0, "a turn started before the task is cut at its creation")
        #expect(early.last?.end == Self.at(150), "and one ending after now at now")
    }

    // MARK: Totals

    @Test func agentTimeAddsThreadsUpAndWaitingTimeCountsEachMomentOnce() {
        let timeline = Self.build([
            Self.lane("a", [Self.turn(0, 10, .inputRequested), Self.turn(30, 40)]),
            Self.lane("b", [Self.turn(0, 10, .inputRequested), Self.turn(20, 40)]),
        ], now: 60)
        #expect(timeline.totals.agent == (10 + 10 + 10 + 20) * 60)
        #expect(timeline.totals.waiting == 20 * 60, "10→30 and 10→20 overlap: 20 minutes of wall clock")
        #expect(timeline.totals.elapsed == 60 * 60)
    }

    @Test func anArchivedTaskStopsAtItsArchive() {
        let timeline = Self.build([Self.lane("a", closed: 90, [Self.turn(0, 10, .inputRequested)])], now: 500, archived: 90)
        #expect(timeline.end == Self.at(90))
        #expect(timeline.totals.elapsed == 90 * 60)
        #expect(timeline.ticks.last?.kind == .archived)
    }

    @Test func unionLengthMergesOverlapsAndSkipsEmptyIntervals() {
        let intervals = [(Self.at(0), Self.at(10)), (Self.at(5), Self.at(15)), (Self.at(20), Self.at(20)), (Self.at(30), Self.at(31))]
        #expect(TaskTimeline.unionLength(intervals) == 16 * 60)
    }

    // MARK: Ticks

    @Test func theTicksAreTheTaskItsPullRequestAndEachChangeOfColourOfItsChecks() {
        let checks = [
            TaskCheckMark(state: "pending", at: Self.at(21), number: 7),
            TaskCheckMark(state: "failing", at: Self.at(25), number: 7),
            TaskCheckMark(state: "failing", at: Self.at(26), number: 7),
            TaskCheckMark(state: "pending", at: Self.at(40), number: 7),
            TaskCheckMark(state: "failing", at: Self.at(45), number: 7),
            TaskCheckMark(state: "passing", at: Self.at(60), number: 7),
        ]
        let timeline = Self.build([], now: 100, archived: 90,
                                  pr: (7, Self.at(20), Self.at(80), Self.at(80)), checks: checks)
        #expect(timeline.ticks.map(\.kind) == [.created, .pullRequestOpened, .checksFailing, .checksFailing, .checksPassing,
                                               .merged, .archived])
        #expect(timeline.ticks.map(\.at) == [Self.t0, Self.at(20), Self.at(25), Self.at(45), Self.at(60), Self.at(80), Self.at(90)])
        #expect(timeline.ticks[1].label == "#7 opened")

        let dropped = Self.build([], pr: (8, Self.at(5), nil, Self.at(9)))
        #expect(dropped.ticks.map(\.kind) == [.created, .pullRequestOpened, .pullRequestClosed])
    }

    // MARK: Scale

    static func scale(_ timeline: TaskTimeline, width: Double = 320) -> TimelineScale {
        TimelineScale(start: timeline.start, end: timeline.end, width: width, activity: timeline.activity)
    }

    @Test func aShortTaskIsDrawnToScale() {
        let timeline = Self.build([Self.lane("a", [Self.turn(0, 10), Self.turn(30, 50)])], now: 60)
        let scale = Self.scale(timeline, width: 300)
        #expect(scale.folds.isEmpty)
        #expect(scale.x(Self.at(30)) == 150)
        #expect(scale.x(Self.at(-5)) == 0 && scale.x(Self.at(999)) == 300)
    }

    @Test func quietHoursFoldIntoBreaksOfFixedWidthAndTheRestKeepsItsProportions() {
        // An hour of work, nine quiet hours overnight, an hour of work.
        let timeline = Self.build([Self.lane("a", [Self.turn(0, 60), Self.turn(600, 660)])], now: 660)
        let scale = Self.scale(timeline, width: 320)
        #expect(scale.folds.count == 1)
        let fold = scale.folds[0]
        #expect(abs((fold.x1 - fold.x0) - TimelineScale.breakWidth) < 0.001)
        #expect(fold.duration > 8 * 3600, "the quiet stretch, less the padding around the turns")
        let before = scale.x(Self.at(60)) - scale.x(Self.at(0))
        let after = scale.x(Self.at(660)) - scale.x(Self.at(600))
        #expect(abs(before - after) < 0.001, "two hours of work, the same width either side of the break")
        #expect(before > 100, "the work takes the room the night gave up")
        #expect(scale.segments.last?.x1 == 320)
    }

    @Test func theMappingIsMonotonicAndItsInverseFindsTheDateBack() {
        let timeline = Self.build([Self.lane("a", [Self.turn(0, 5), Self.turn(300, 310), Self.turn(2_000, 2_030)])], now: 2_100)
        let scale = Self.scale(timeline, width: 320)
        #expect(!scale.folds.isEmpty)
        var previous = -1.0
        for minute in stride(from: 0.0, through: 2_100, by: 7) {
            let x = scale.x(Self.at(minute))
            #expect(x >= previous)
            previous = x
            let back = scale.date(atX: x)
            let segment = scale.segments.first { Self.at(minute) <= $0.end }!
            // Inside a fold a point stands for minutes: the inverse is exact up to what one point covers there.
            let tolerance = segment.duration / max(1, segment.x1 - segment.x0) + 1
            #expect(abs(back.timeIntervalSince(Self.at(minute))) <= tolerance)
        }
    }

    @Test func aNarrowTimelineKeepsFewerBreaksAndNeverGivesThemMostOfItsWidth() {
        // Six bursts of work separated by quiet hours of growing length.
        let starts: [Double] = [0, 360, 840, 1_440, 2_160, 3_000]
        let turns = starts.map { Self.turn($0, $0 + 5) }
        let timeline = Self.build([Self.lane("a", turns)], now: 3_200)
        let wide = Self.scale(timeline, width: 480)
        let narrow = Self.scale(timeline, width: 100)
        #expect(narrow.folds.count <= Int(100 / TimelineScale.pointsPerFold))
        #expect(narrow.folds.count < wide.folds.count)
        let foldWidth = narrow.folds.map { $0.x1 - $0.x0 }.reduce(0, +)
        #expect(foldWidth <= 100 * TimelineScale.maximumFoldShare + 0.001)
        // The longest quiet stretches are the ones folded.
        let longestQuiet = wide.folds.map(\.duration).max()!
        #expect(narrow.folds.contains { $0.duration == longestQuiet })
    }

    @Test func nothingFoldsWhenNothingHappened() {
        let scale = TimelineScale(start: Self.t0, end: Self.at(600), width: 320, activity: [])
        #expect(scale.folds.isEmpty)
    }

    @Test func aSecondsLongTurnStaysVisibleAndInsideTheTimeline() {
        let scale = TimelineScale(start: Self.t0, end: Self.at(6_000), width: 320, activity: [])
        let blip = scale.extent(from: Self.at(3_000), to: Self.at(3_000).addingTimeInterval(4), minimumWidth: 3)
        #expect(blip.upperBound - blip.lowerBound == 3)
        let atEnd = scale.extent(from: Self.at(6_000), to: Self.at(6_000), minimumWidth: 3)
        #expect(atEnd.upperBound == 320 && atEnd.lowerBound == 317)
    }

    // MARK: Durations

    @Test func durationsReadFromSecondsToDays() {
        #expect(DurationText.short(42) == "42 s")
        #expect(DurationText.short(12 * 60 + 5) == "12 min")
        #expect(DurationText.short(3 * 3600) == "3 h")
        #expect(DurationText.short(3 * 3600 + 5 * 60) == "3 h 05")
        #expect(DurationText.short(2 * 86_400 + 4 * 3600 + 59) == "2 d 4 h")
        #expect(DurationText.short(-3) == "0 s")
    }

    // MARK: Log and store

    @Test func theLogKeepsAClosedThreadOnceAndOnlyTheChangesOfItsChecks() {
        var log = TaskTimelineLog()
        log = log.adding(Self.lane("a", [Self.turn(0, 1)], open: 2, state: .running))
        log = log.adding(Self.lane("a", [Self.turn(0, 1), Self.turn(3, 4)]))
        #expect(log.lanes.count == 1)
        #expect(log.lanes[0].turns.count == 2)
        #expect(log.lanes[0].openTurnSince == nil && log.lanes[0].state == nil)

        log = log.recording(checks: "pending", number: 7, at: Self.at(1))
        log = log.recording(checks: "pending", number: 7, at: Self.at(2))
        log = log.recording(checks: "failing", number: 7, at: Self.at(3))
        log = log.recording(checks: "none", number: 7, at: Self.at(4))
        #expect(log.checks.map(\.state) == ["pending", "failing"])
    }

    @Test func theStoreRoundTripsAndAClosedTaskLeavesItsTotalsInTheHistory() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-timeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let record = TaskRecord(scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/tmp/acme",
                                scopeSlug: "acme", name: "Timed", slug: "timed", branch: "feat/timed", root: "/tmp/x",
                                createdAt: Self.t0, archivedAt: Self.at(100))
        let records = TaskRecordStore(home: home)
        try await records.save(record)
        let timelines = TaskTimelineStore(home: home)
        await timelines.update(record.id) { $0.adding(Self.lane("a", closed: 100, [Self.turn(0, 30, .inputRequested), Self.turn(40, 70)])) }
        #expect(await timelines.load(record.id).lanes.count == 1)
        #expect(await records.loadAll().records.map(\.id) == [record.id], "the timeline is not taken for a task")

        try await records.delete(record.id)
        #expect(!FileManager.default.fileExists(atPath: timelines.url(for: record.id).path))
        let closed = ActivityHistory.load(home: home).compactMap(\.task)
        let agent = try #require(closed.first?.agentSeconds), waiting = try #require(closed.first?.waitingSeconds)
        #expect(agent == 3_600, "\(agent.bitPattern)")
        #expect(waiting == 600)
    }

    @Test func aRecordWithoutTurnsLeavesNoTotals() {
        let record = TaskRecord(scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/tmp/acme",
                                scopeSlug: "acme", name: "Idle", slug: "idle", branch: "feat/idle", root: "/tmp/x", createdAt: Self.t0)
        #expect(record.snapshot(lanes: [Self.lane("a", [])]).agentSeconds == nil)
    }

    // MARK: Pull request dates

    @Test func theLinkKeepsWhatGitHubDatesAndSaysWhenItIsStale() throws {
        let json = """
        {"number": 7, "title": "T", "headRefName": "h", "baseRefName": "main", "url": "https://github.com/acme/api/pull/7",
         "state": "MERGED", "createdAt": "2026-10-01T10:00:00Z", "mergedAt": "2026-10-02T10:00:00Z", "closedAt": "2026-10-02T10:00:00Z"}
        """
        let pr = try PullRequest.parseOne(json: Data(json.utf8))
        #expect(pr.createdAt == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        let link = LinkedPullRequest(pr)
        #expect(link.mergedAt == pr.mergedAt)
        #expect(!link.isStale(against: pr))
        var older = link
        older.mergedAt = nil
        #expect(older.isStale(against: pr))

        let open = try PullRequest.parseOne(json: Data("""
        {"number": 8, "title": "T", "headRefName": "h", "baseRefName": "main", "url": "https://github.com/acme/api/pull/8",
         "mergedAt": null, "closedAt": "0001-01-01T00:00:00Z"}
        """.utf8))
        #expect(open.mergedAt == nil && open.closedAt == nil, "null and the zero time both mean never")
    }
}
