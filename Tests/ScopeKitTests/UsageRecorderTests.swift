import Foundation
import Testing
@testable import ScopeCore

/// The writer: batching, order, the off switch, the size cap, the history kept and cleared.
@Suite struct UsageRecorderTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "scope-usage-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static let october = DateComponents(calendar: UsageLog.utc, year: 2026, month: 10, day: 15, hour: 9).date!

    static func event(_ id: String, at date: Date = october, kind: UsageEvent.Kind = .click) -> UsageEvent {
        UsageEvent(at: date, kind: kind, id: id, source: .mouse)
    }

    /// A long interval, so only explicit flushes and the batch size write anything.
    static let slow = UsageRecorder.Limits(flushInterval: .seconds(3600))

    @Test func nothingIsWrittenUntilAFlushThenEverythingInOrder() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: Self.slow)
        for index in 0..<5 { recorder.record(Self.event("sidebar.e\(index)")) }
        #expect(log.files().isEmpty)
        await recorder.flush()
        #expect(log.files().map(\.lastPathComponent) == ["usage-2026-10.jsonl"])
        let ids = log.read(since: .distantPast, until: .distantFuture).map(\.id)
        #expect(ids == (0..<5).map { "sidebar.e\($0)" })
    }

    @Test func aFullBatchIsWrittenWithoutWaiting() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: .init(flushInterval: .seconds(3600), batchSize: 3))
        for index in 0..<3 { recorder.record(Self.event("sidebar.e\(index)")) }
        // A flush of an empty buffer is the barrier: it runs after the three events, which already went out.
        await recorder.flush()
        #expect(log.read(since: .distantPast, until: .distantFuture).count == 3)
    }

    @Test func theTickerFlushesOnItsOwn() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: .init(flushInterval: .milliseconds(50)))
        recorder.record(Self.event("sidebar.tick"))
        for _ in 0..<40 where log.files().isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(log.read(since: .distantPast, until: .distantFuture).map(\.id) == ["sidebar.tick"])
        _ = recorder
    }

    @Test func eventsGoToTheFileOfTheirMonth() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: Self.slow)
        let september = DateComponents(calendar: UsageLog.utc, year: 2026, month: 9, day: 30, hour: 23).date!
        recorder.record(Self.event("a.one", at: september))
        recorder.record(Self.event("a.two"))
        await recorder.flush()
        #expect(log.files().map(\.lastPathComponent) == ["usage-2026-09.jsonl", "usage-2026-10.jsonl"])
        #expect(log.firstEventDate() == september)
        let firstOfOctober = DateComponents(calendar: UsageLog.utc, year: 2026, month: 10, day: 1).date!
        #expect(log.read(since: firstOfOctober, until: .distantFuture).map(\.id) == ["a.two"])
    }

    @Test func offDropsWhatWaitsAndWhatComesAfter() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: Self.slow)
        recorder.record(Self.event("a.before"))
        recorder.setEnabled(false)
        recorder.record(Self.event("a.during"))
        recorder.setEnabled(true)
        recorder.record(Self.event("a.after"))
        await recorder.flush()
        #expect(log.read(since: .distantPast, until: .distantFuture).map(\.id) == ["a.after"])
    }

    @Test func aFullMonthStopsGrowing() async throws {
        let log = UsageLog(directory: Self.directory())
        let line = try Self.event("a.0").line().count + 1
        let recorder = UsageRecorder(log: log, limits: .init(flushInterval: .seconds(3600), maxFileBytes: line * 2))
        recorder.record(Self.event("a.0"))
        recorder.record(Self.event("a.1"))
        await recorder.flush()
        recorder.record(Self.event("a.2"))
        await recorder.flush()
        #expect(log.read(since: .distantPast, until: .distantFuture).map(\.id) == ["a.0", "a.1"])
    }

    @Test func pruningRemovesWholeMonthsPastTheRetention() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: Self.slow)
        let march = DateComponents(calendar: UsageLog.utc, year: 2026, month: 3, day: 10).date!
        let april = DateComponents(calendar: UsageLog.utc, year: 2026, month: 4, day: 25).date!
        recorder.record(Self.event("a.march", at: march))
        recorder.record(Self.event("a.april", at: april))
        recorder.record(Self.event("a.october"))
        await recorder.flush()
        // 180 days before 15 October is 18 April: March is gone, April straddles the cutoff and stays.
        await recorder.prune(now: Self.october)
        #expect(log.files().map(\.lastPathComponent) == ["usage-2026-04.jsonl", "usage-2026-10.jsonl"])
    }

    @Test func clearingDeletesTheHistoryButKeepsTheRegistry() async throws {
        let log = UsageLog(directory: Self.directory())
        let recorder = UsageRecorder(log: log, limits: Self.slow)
        recorder.register([UsageElement(id: "sidebar.thread", label: "Thread row")])
        recorder.record(Self.event("sidebar.thread"))
        await recorder.flush()
        recorder.record(Self.event("sidebar.queued"))
        await recorder.clear()
        await recorder.flush()
        #expect(log.files().isEmpty)
        #expect(log.readRegistry().elements["sidebar.thread"]?.label == "Thread row")
    }

    @Test func theRegistryIsWrittenOnFlushAndReadBackByTheNextRecorder() async throws {
        let directory = Self.directory()
        let first = UsageRecorder(log: UsageLog(directory: directory), enabled: false, limits: Self.slow)
        first.register([UsageElement(id: "command.new-thread", label: "New Thread")])
        await first.flush()
        let second = UsageRecorder(log: UsageLog(directory: directory), limits: Self.slow)
        second.register([UsageElement(id: "sheet.graph", label: "Graph")])
        await second.flush()
        #expect(Set(UsageLog(directory: directory).readRegistry().elements.keys) == ["command.new-thread", "sheet.graph"])
    }
}
