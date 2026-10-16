import Foundation
import Testing
@testable import ScopeAdapters

/// `TokenLedger` and its store: model calls counted once, summed per thread, task and scope over rolling windows.
@Suite struct TokenLedgerTests {
    typealias F = TranscriptFixtures

    /// 2026-10-16 15:00 in Paris (13:00 UTC).
    static let now = Date(timeIntervalSince1970: 1_792_155_600)
    static let paris: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    static func entry(_ id: String, hoursAgo: Double, output: Int, model: String = "claude-opus-5-5") -> TranscriptUsageEntry {
        TranscriptUsageEntry(id: id, model: model, at: now.addingTimeInterval(-hoursAgo * 3600), counts: TokenCounts(output: output))
    }

    static func ledger(_ threads: [(id: String, task: String?, scope: String, entries: [TranscriptUsageEntry])]) -> TokenLedger {
        var ledger = TokenLedger()
        for thread in threads {
            ledger.attribute(thread: thread.id, title: "t-" + thread.id, scope: thread.scope, task: thread.task)
            ledger.record(thread.entries, thread: thread.id)
        }
        return ledger
    }

    // MARK: Counting

    @Test func aResponseWrittenAsSeveralLinesCountsOnce() {
        var ledger = TokenLedger()
        ledger.attribute(thread: "a", title: "A", scope: "s", task: nil)
        let lines = [F.response1Thinking, F.response1Text, F.response1ToolUse, F.response2].compactMap { TranscriptUsage.entry(Data($0.utf8)) }
        // The first response's lines split across two reads still count once.
        ledger.record(Array(lines.prefix(2)), thread: "a")
        ledger.record(Array(lines.dropFirst(2)), thread: "a")
        let total = ledger.threads["a"]!.total
        #expect(total == TokenCounts(input: 34, output: 502, cacheCreation: 36_610, cacheCreation1h: 36_610, cacheRead: 85_312))
        #expect(ledger.threads["a"]!.buckets.count == 1)
        #expect(ledger.threads["a"]!.seen.count == 2)
    }

    @Test func callsGoIntoOneBucketPerMinuteAndModelInTimeOrder() {
        let ledger = Self.ledger([("a", nil, "s", [
            Self.entry("m1", hoursAgo: 1, output: 10),
            Self.entry("m2", hoursAgo: 1, output: 5),
            Self.entry("m3", hoursAgo: 1, output: 7, model: "claude-haiku-5-5"),
            Self.entry("m4", hoursAgo: 3, output: 1),
        ])])
        let buckets = ledger.threads["a"]!.buckets
        #expect(buckets.map(\.counts.output) == [1, 15, 7])
        #expect(buckets.map(\.minute) == buckets.map(\.minute).sorted())
    }

    @Test func recordingForAnUnknownThreadDoesNothing() {
        var ledger = TokenLedger()
        let recorded = ledger.record([Self.entry("m1", hoursAgo: 1, output: 1)], thread: "ghost")
        #expect(!recorded)
        #expect(ledger.threads.isEmpty)
    }

    // MARK: Windows

    @Test func windowsAreFiveHoursTheCalendarDayAndSevenDays() {
        let ledger = Self.ledger([("a", nil, "s", [
            Self.entry("now", hoursAgo: 0.1, output: 1),
            Self.entry("4h", hoursAgo: 4.9, output: 10),
            // 15:00 − 5h01 is 09:59 in Paris: out of the five hours, still today.
            Self.entry("5h", hoursAgo: 5.02, output: 100),
            // 15:00 − 16h is yesterday 23:00.
            Self.entry("yesterday", hoursAgo: 16, output: 1_000),
            Self.entry("6d", hoursAgo: 6 * 24, output: 10_000),
            Self.entry("8d", hoursAgo: 8 * 24, output: 100_000),
        ])])
        let windows = ledger.snapshot(now: Self.now, calendar: Self.paris).all
        #expect(windows.fiveHours.counts.output == 11)
        #expect(windows.today.counts.output == 111)
        #expect(windows.sevenDays.counts.output == 11_111)
        #expect(ledger.threads["a"]!.total.output == 111_111)
    }

    @Test func windowsKeepTheModelsApart() {
        let ledger = Self.ledger([("a", nil, "s", [
            Self.entry("m1", hoursAgo: 1, output: 3),
            Self.entry("m2", hoursAgo: 1, output: 4, model: "claude-haiku-5-5"),
        ])])
        let window = ledger.snapshot(now: Self.now, calendar: Self.paris).all.fiveHours
        #expect(window.byModel == ["claude-opus-5-5": TokenCounts(output: 3), "claude-haiku-5-5": TokenCounts(output: 4)])
    }

    @Test func threadsAddUpPerTaskAndPerScope() {
        let ledger = Self.ledger([
            ("a", "task1", "s1", [Self.entry("a1", hoursAgo: 1, output: 1)]),
            ("b", "task1", "s1", [Self.entry("b1", hoursAgo: 30, output: 10)]),
            ("c", nil, "s1", [Self.entry("c1", hoursAgo: 2, output: 100)]),
            ("d", "task2", "s2", [Self.entry("d1", hoursAgo: 3, output: 1_000)]),
        ])
        let snapshot = ledger.snapshot(now: Self.now, calendar: Self.paris)
        #expect(snapshot.tasks["task1"]?.total.output == 11)
        #expect(snapshot.tasks["task1"]?.windows.fiveHours.counts.output == 1)
        #expect(snapshot.tasks["task2"]?.total.output == 1_000)
        #expect(snapshot.scopes["s1"]?.windows.sevenDays.counts.output == 111)
        #expect(snapshot.scopes["s2"]?.windows.fiveHours.counts.output == 1_000)
        #expect(snapshot.all.sevenDays.counts.output == 1_111)
        #expect(snapshot.topThreads(2).map(\.id) == ["d", "c"])
    }

    // MARK: Retention

    @Test func pruningDropsOldMinutesButKeepsTheTotal() {
        var ledger = Self.ledger([("a", "t", "s", [
            Self.entry("recent", hoursAgo: 1, output: 1),
            Self.entry("old", hoursAgo: 9 * 24, output: 10),
        ])])
        ledger.prune(now: Self.now)
        let thread = ledger.threads["a"]!
        #expect(thread.buckets.map(\.counts.output) == [1])
        #expect(Set(thread.seen.keys) == ["recent"])
        #expect(thread.total.output == 11)
    }

    @Test func pruningForgetsAThreadQuietForThreeMonthsAndItsTranscripts() {
        var ledger = Self.ledger([
            ("old", nil, "s", [Self.entry("o", hoursAgo: 100 * 24, output: 1)]),
            ("new", nil, "s", [Self.entry("n", hoursAgo: 1, output: 1)]),
        ])
        ledger.files = ["/t/old.jsonl": .init(thread: "old", offset: 10), "/t/new.jsonl": .init(thread: "new", offset: 10)]
        ledger.prune(now: Self.now)
        #expect(Set(ledger.threads.keys) == ["new"])
        #expect(Set(ledger.files.keys) == ["/t/new.jsonl"])
    }

    // MARK: Store

    static func home() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "token-ledger-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func append(_ lines: [String], to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(F.file(lines).utf8))
        try handle.close()
    }

    /// The fixture lines are from 2026-09-15; the windows are looked at a minute later.
    static let fixtureNow = Date(timeIntervalSince1970: 1_789_474_200)

    @Test func theStoreReadsOnlyWhatWasAppendedAndRemembersItAcrossLaunches() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appending(path: "projects/p/9b1d.jsonl")
        let source = TokenLedgerStore.Source(thread: "a", title: "A", scope: "s", task: "t", transcript: transcript.path)

        try Self.append([F.prompt, F.response1Thinking, F.response1Text], to: transcript)
        let first = await TokenLedgerStore(home: home).scan([source], now: Self.fixtureNow, calendar: Self.paris)
        #expect(first.threads["a"]?.total.output == 316)

        // A new launch reads the saved offset: the lines already counted are not read again.
        try Self.append([F.response1ToolUse, F.toolResult, F.response2], to: transcript)
        let store = TokenLedgerStore(home: home)
        let second = await store.scan([source], now: Self.fixtureNow, calendar: Self.paris)
        #expect(second.threads["a"]?.total.output == 502)
        #expect(second.tasks["t"]?.windows.fiveHours.counts.output == 502)

        let third = await store.scan([source], now: Self.fixtureNow, calendar: Self.paris)
        #expect(third == second)
    }

    @Test func subagentsCountForTheirThreadAndARepeatedMessageCountsOnce() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appending(path: "projects/p/9b1d.jsonl")
        try Self.append([F.response1Thinking], to: transcript)
        // A forked subagent's transcript can begin with its parent's messages.
        try Self.append([F.response1Text, F.response2], to: home.appending(path: "projects/p/9b1d/subagents/agent-x.jsonl"))

        let source = TokenLedgerStore.Source(thread: "a", title: "A", scope: "s", task: nil, transcript: transcript.path)
        let snapshot = await TokenLedgerStore(home: home).scan([source], now: Self.fixtureNow, calendar: Self.paris)
        #expect(snapshot.threads["a"]?.total.output == 502)
    }

    @Test func aClosedThreadKeepsItsTotalsAndAResumingThreadCountsWhatComesNext() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appending(path: "projects/p/9b1d.jsonl")
        try Self.append([F.response2], to: transcript)
        let store = TokenLedgerStore(home: home)
        _ = await store.scan([.init(thread: "a", title: "A", scope: "s", task: "t", transcript: transcript.path)],
                             now: Self.fixtureNow, calendar: Self.paris)

        // Thread a is closed; thread b resumes the same session and its transcript grows.
        try Self.append([F.response1Thinking], to: transcript)
        let snapshot = await store.scan([.init(thread: "b", title: "B", scope: "s", task: "t", transcript: transcript.path)],
                                        now: Self.fixtureNow, calendar: Self.paris)
        #expect(snapshot.threads["a"]?.total.output == 186)
        #expect(snapshot.threads["b"]?.total.output == 316)
        #expect(snapshot.tasks["t"]?.total.output == 502)
        #expect(snapshot.all.fiveHours.counts.output == 502)
    }

    @Test func aMissingTranscriptIsNotAnError() async {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = await TokenLedgerStore(home: home).scan(
            [.init(thread: "a", title: "A", scope: "s", task: nil, transcript: "/nowhere/x.jsonl")], now: Self.now, calendar: Self.paris)
        #expect(snapshot.threads["a"]?.total.isZero == true)
    }

    @Test func aThreadThatNeverMadeACallGoesOnceClosed() async {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenLedgerStore(home: home)
        _ = await store.scan([.init(thread: "a", title: "A", scope: "s", task: nil, transcript: "/nowhere/x.jsonl")],
                             now: Self.now, calendar: Self.paris)
        let snapshot = await store.scan([], now: Self.now, calendar: Self.paris)
        #expect(snapshot.threads.isEmpty)
    }
}
