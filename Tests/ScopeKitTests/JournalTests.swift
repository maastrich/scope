import Foundation
import Testing
@testable import ScopeCore

/// The event journal under `SCOPE_HOME/logs`: what a line may hold, how it is written, condensed and pruned.
@Suite struct JournalTests {
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    /// A recorder whose clock the test moves, and whose flushes only happen when asked.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    static func recorder(_ folder: URL, clock: Clock, limits: JournalRecorder.Limits = .init()) -> JournalRecorder {
        let (ticks, _) = AsyncStream.makeStream(of: Void.self)
        return JournalRecorder(log: JournalLog(directory: folder), limits: limits, ticks: ticks, now: { clock.now })
    }

    // MARK: Privacy

    /// What the app could be handed by mistake: a path, a prompt, a branch, a title, a URL, a token.
    static let poison = [
        "/Users/me/work/acme/secret-plan",
        "Fix the login of acme and send the token to bob",
        "feat/secret-plan",
        "Could not create task “secret plan”",
        "https://github.com/acme/secret-plan/pull/12",
        "ghp_AbCdEf0123456789xyzXYZ",
        "~/Library/secret",
        String(repeating: "a", count: 80),
    ]

    /// Every string a line may carry: an id, a UUID, an enum value or slug, a version, a date, a title template.
    static func allowed(_ key: String, _ value: String) -> Bool {
        if key == "at" { return (try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))) != nil }
        if key == "template" { return value == JournalEvent.redacted || (!value.contains("/") && value.count <= 120 && !value.contains("\n")) }
        return value.range(of: #"^[a-z0-9][a-z0-9._:+-]{0,63}$"#, options: .regularExpression) != nil
    }

    static func strings(of event: JournalEvent) throws -> [(String, String)] {
        let object = try JSONSerialization.jsonObject(with: try event.line()) as? [String: Any] ?? [:]
        return object.compactMap { key, value in (value as? String).map { (key, $0) } }
    }

    @Test(arguments: JournalEvent.Kind.allCases)
    func noKindCarriesAnythingPersonal(_ kind: JournalEvent.Kind) throws {
        for poison in Self.poison {
            let event = JournalEvent(kind: kind, name: poison, title: ProblemTitle(verbatim: poison), outcome: poison, cause: poison,
                                     severity: poison, scope: poison, task: poison, thread: poison, source: poison,
                                     client: poison, version: poison, previous: poison, seconds: 1.5, count: 2)
            let line = String(decoding: try event.line(), as: UTF8.self)
            #expect(!line.contains("secret"), "\(kind.rawValue) let “\(poison)” through: \(line)")
            #expect(!line.contains("token"), "\(kind.rawValue): \(line)")
            #expect(!line.contains("Ab"), "\(kind.rawValue): \(line)")
            for (key, value) in try Self.strings(of: event) {
                #expect(Self.allowed(key, value), "\(kind.rawValue).\(key) = \(value)")
            }
        }
    }

    @Test(arguments: JournalEvent.Kind.allCases)
    func everyKindKeepsWhatIsMeantToBeKept(_ kind: JournalEvent.Kind) throws {
        let task = "secret plan"
        let event = JournalEvent(at: Self.date("2026-10-27T10:00:00Z"), kind: kind, name: "task.new", title: "The setup of \(task) failed", outcome: "refused",
                                 cause: "budget-tasks", severity: "error", scope: "maastrich", task: "7b520cd86149",
                                 thread: "0723ed59d916", source: "agent", client: "mcp", version: "0.31.0",
                                 previous: "0.30.2", seconds: 0.123_456, count: 3)
        for (key, value) in try Self.strings(of: event) {
            #expect(Self.allowed(key, value), "\(kind.rawValue).\(key) = \(value)")
            #expect(value != JournalEvent.redacted, "\(kind.rawValue).\(key) was redacted")
        }
        #expect(event.seconds == 0.123)
        #expect(JournalEvent.decode(line: try event.line()) == event)
    }

    @Test func aProblemTitleKeepsItsWordsAndDropsWhatWasInterpolated() {
        let task = "secret plan"
        let path = "/Users/me/work"
        let title: ProblemTitle = "The setup of \(task) failed in \(path)"
        #expect(title.text == "The setup of secret plan failed in /Users/me/work")
        #expect(title.template == "The setup of {} failed in {}")
        #expect(ProblemTitle(verbatim: "claude not found in PATH").template == nil)
        let literal: ProblemTitle = "Shell environment fallback"
        #expect(literal.template == "Shell environment fallback")
    }

    @Test func problemCausesAreClassifiedFromTheDetailWhichIsNotKept() {
        #expect(ProblemCause.classify("npm ERR! 401 Unauthorized - GET https://npm.pkg.github.com/@acme%2fui") == .auth)
        #expect(ProblemCause.classify("npm WARN EBADENGINE Unsupported engine { required: { node: '>=22' } }") == .engines)
        #expect(ProblemCause.classify("zsh: command not found: pnpm\n[api] failed: exit 127") == .notFound)
        #expect(ProblemCause.classify("fatal: Unable to create '/x/.git/index.lock': File exists.") == .conflict)
        #expect(ProblemCause.classify("Could not resolve host: github.com") == .network)
        #expect(ProblemCause.classify("[web] failed: exit 1") == .exit)
        #expect(ProblemCause.classify("something odd") == .unknown)
        #expect(ProblemCause.classify(nil) == .unknown)
    }

    // MARK: Writing

    @Test func eventsAreBatchedIntoTheMonthFile() async throws {
        let folder = Self.folder()
        let clock = Clock(Self.date("2026-10-27T10:00:00Z"))
        let recorder = Self.recorder(folder, clock: clock)
        _ = await recorder.beginSession(version: "0.32.0")
        recorder.record(JournalEvent(at: clock.now, kind: .control, name: "list", outcome: "ok", seconds: 0.01))
        recorder.record(JournalEvent(at: clock.now, kind: .gh, name: "pr.list", outcome: "failed", seconds: 1.2))
        let log = JournalLog(directory: folder)
        #expect(log.read(since: .distantPast, until: .distantFuture).isEmpty)
        await recorder.flush()
        #expect(log.fileURL(for: clock.now).lastPathComponent == "events-2026-10.jsonl")
        #expect(log.read(since: .distantPast, until: .distantFuture).map(\.kind) == [.control, .gh])
    }

    @Test func aKindPastItsDailyCapIsCountedNotWritten() async throws {
        let folder = Self.folder()
        let clock = Clock(Self.date("2026-10-27T10:00:00Z"))
        var limits = JournalRecorder.Limits()
        limits.dailyKindCap = 3
        let recorder = Self.recorder(folder, clock: clock, limits: limits)
        for _ in 0..<10 { recorder.record(JournalEvent(at: clock.now, kind: .hookDropped, cause: "unknown-thread")) }
        recorder.record(JournalEvent(at: clock.now, kind: .control, name: "list", outcome: "ok"))
        // The next day's first event closes the count of the day before.
        clock.now = Self.date("2026-10-28T08:00:00Z")
        recorder.record(JournalEvent(at: clock.now, kind: .hookDropped, cause: "unknown-thread"))
        await recorder.flush()
        let events = JournalLog(directory: folder).read(since: .distantPast, until: .distantFuture)
        #expect(events.filter { $0.kind == .hookDropped }.count == 4)
        let dropped = events.filter { $0.kind == .journalDropped }
        #expect(dropped.map(\.count) == [7])
        #expect(dropped.first?.name == "hook.dropped")
        #expect(dropped.first?.day == "2026-10-27")
    }

    // MARK: Summaries and retention

    @Test func aNewDayCondensesTheOneBeforeAndKeepsItsSummaryPastTheRawRetention() async throws {
        let folder = Self.folder()
        let clock = Clock(Self.date("2026-10-27T10:00:00Z"))
        var limits = JournalRecorder.Limits()
        limits.rawRetentionDays = 2
        let recorder = Self.recorder(folder, clock: clock, limits: limits)
        for seconds in [1.0, 2, 3, 4, 10] {
            recorder.record(JournalEvent(at: clock.now, kind: .taskSetup, outcome: "ok", seconds: seconds))
        }
        recorder.record(JournalEvent(at: clock.now, kind: .problem, name: "appmodel+tasks:performsetup",
                                     title: "The setup of {} failed", cause: "auth", severity: "error"))
        recorder.record(JournalEvent(at: clock.now, kind: .control, name: "task.new", outcome: "refused", cause: "budget-tasks", seconds: 0.002))
        clock.now = Self.date("2026-10-28T09:00:00Z")
        await recorder.flush()

        let log = JournalLog(directory: folder)
        let summaries = log.readSummaries()
        #expect(summaries.map(\.day) == ["2026-10-27"])
        let day = try #require(summaries.first)
        #expect(day.total == 7)
        #expect(day.kinds["task.setup"] == 5)
        #expect(day.outcomes["control refused"] == 1)
        #expect(day.causes["control budget-tasks"] == 1)
        #expect(day.durations["task.setup"] == .init(count: 5, p50: 3, p90: 10, max: 10))
        #expect(day.durations["control task.new"]?.count == 1)
        #expect(day.problems.first?.template == "The setup of {} failed")

        // Days later, the raw lines are gone; the summary is not, and is not written twice.
        clock.now = Self.date("2026-11-02T09:00:00Z")
        recorder.record(JournalEvent(at: clock.now, kind: .appStart, version: "0.32.0"))
        await recorder.flush()
        let raw = log.read(since: .distantPast, until: .distantFuture)
        #expect(raw.allSatisfy { $0.day >= "2026-10-31" })
        #expect(log.readSummaries().map(\.day) == ["2026-10-27"])
    }

    // MARK: Sessions

    @Test func aSessionThatNeverQuitIsReportedUncleanWithItsLastSignOfLife() async throws {
        let folder = Self.folder()
        let clock = Clock(Self.date("2026-10-27T10:00:00Z"))
        var limits = JournalRecorder.Limits()
        limits.heartbeat = 60
        let first = Self.recorder(folder, clock: clock, limits: limits)
        #expect(await first.beginSession(version: "0.31.0") == nil)
        clock.now = Self.date("2026-10-27T10:30:00Z")
        await first.flush()

        clock.now = Self.date("2026-10-27T12:00:00Z")
        let second = Self.recorder(folder, clock: clock, limits: limits)
        let previous = try #require(await second.beginSession(version: "0.32.0"))
        #expect(previous.end == .unclean)
        #expect(previous.version == "0.31.0")
        #expect(previous.length == 30 * 60)

        clock.now = Self.date("2026-10-27T13:00:00Z")
        await second.endSession(reason: .update)
        let third = Self.recorder(folder, clock: clock, limits: limits)
        let closed = try #require(await third.beginSession(version: "0.33.0"))
        #expect(closed.end == .update)
        #expect(closed.length == 3600)
    }

    @Test func aCrashReportSinceTheSessionBeganTellsACrashFromAKill() throws {
        let folder = Self.folder()
        let started = Date.now.addingTimeInterval(-3600)
        #expect(!SessionEnd.crashReported(process: "Scope", since: started, folder: folder))
        FileManager.default.createFile(atPath: folder.appending(path: "Scope Debug-2026-10-27-101500.ips").path, contents: Data())
        FileManager.default.createFile(atPath: folder.appending(path: "scope-2026-10-27-093000.ips").path, contents: Data())
        #expect(!SessionEnd.crashReported(process: "Scope", since: started, folder: folder))
        FileManager.default.createFile(atPath: folder.appending(path: "Scope-2026-10-27-101500.ips").path, contents: Data())
        #expect(SessionEnd.crashReported(process: "Scope", since: started, folder: folder))
        #expect(!SessionEnd.crashReported(process: "Scope", since: .now.addingTimeInterval(60), folder: folder))
    }

    // MARK: Size

    /// A busy day, scaled from the week analysed in `docs/research/logs-2026-10.md` (≈130 tasks, 550 turns and 650
    /// control calls in 7 days; the busiest day had 2.75× the mean of control calls), plus the background `gh`
    /// refresh: 10 open tasks polled every 5 min for 12 h. Keeps the size decision honest: see `rawRetentionDays`.
    static func busyDay(_ start: Date) -> [JournalEvent] {
        var events: [JournalEvent] = []
        func at(_ i: Int, _ n: Int) -> Date { start.addingTimeInterval(Double(i) * 43_200 / Double(max(n, 1))) }
        let task = "7b520cd86149", thread = "0723ed59d916"
        for i in 0..<4 { events.append(JournalEvent(at: at(i, 4), kind: .appStart, outcome: "clean", version: "0.31.0", previous: "0.31.0", seconds: 18_000, count: 12)) }
        for i in 0..<4 { events.append(JournalEvent(at: at(i, 4), kind: .appStop, cause: "quit", seconds: 18_000, count: 6)) }
        for i in 0..<4 { events.append(JournalEvent(at: at(i, 4), kind: .threadsRelaunch, count: 6)) }
        for i in 0..<255 {
            events.append(JournalEvent(at: at(i, 255), kind: .control, name: "thread.wait", outcome: i % 20 == 0 ? "refused" : "ok",
                                       cause: i % 20 == 0 ? "budget-tasks" : nil, task: task, thread: thread, source: "agent", client: "mcp", seconds: 12.345))
        }
        for kind in [JournalEvent.Kind.taskCreate, .taskSetup, .taskArchive] {
            for i in 0..<51 { events.append(JournalEvent(at: at(i, 51), kind: kind, outcome: "ok", scope: "maastrich", task: task, seconds: 42.5, count: 1)) }
        }
        for i in 0..<24 { events.append(JournalEvent(at: at(i, 24), kind: .taskGC, outcome: "ok", seconds: 3.2, count: 0)) }
        for i in 0..<1_440 { events.append(JournalEvent(at: at(i, 1_440), kind: .gh, name: "pr.list", outcome: "ok", seconds: 0.834)) }
        for i in 0..<40 { events.append(JournalEvent(at: at(i, 40), kind: .turnInterrupted, cause: "sent", task: task, thread: thread)) }
        for i in 0..<20 { events.append(JournalEvent(at: at(i, 20), kind: .turnSettled, cause: "island", thread: thread)) }
        for i in 0..<10 { events.append(JournalEvent(at: at(i, 10), kind: .turnResume, thread: thread)) }
        for i in 0..<60 {
            events.append(JournalEvent(at: at(i, 60), kind: .problem, name: "appmodel+tasks:performsetup",
                                       title: "The setup of {} failed", outcome: "toast", cause: "auth", severity: "error",
                                       scope: "maastrich", task: task))
        }
        for i in 0..<100 { events.append(JournalEvent(at: at(i, 100), kind: .hookDropped, cause: "unknown-thread")) }
        return events
    }

    @Test func aBusyDayStaysSmall() throws {
        let events = Self.busyDay(Self.date("2026-10-20T07:00:00Z"))
        let raw = try events.reduce(0) { $0 + (try $1.line().count) + 1 }
        let summary = try JSONEncoder().encode(JournalDaySummary(day: "2026-10-20", events: events)).count + 1
        // Measured: printed so the PR can quote them.
        print("journal size: \(events.count) events, \(raw) bytes raw, \(summary) bytes summarized")
        #expect(raw < 600_000)
        #expect(summary < 8_000)
        // At this rate the default retention bounds the raw files, and a year of summaries stays small.
        #expect(raw * JournalRecorder.Limits().rawRetentionDays < 20 << 20)
        #expect(summary * 365 < 3 << 20)
    }
}
