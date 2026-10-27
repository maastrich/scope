import Foundation
import Synchronization

/// Batches journal events and appends them to the month's file off the main thread, the way `UsageRecorder` does.
///
/// Unlike usage it is always on: it records how the app behaves, not what the user does, and nothing in it is
/// personal (`JournalEvent.token`). `record` is `nonisolated` and only yields into a stream. Once a day — at the first
/// write of a new UTC day, and at launch — the days before are condensed into `summary.jsonl` and raw lines older
/// than `rawRetentionDays` go.
public actor JournalRecorder {
    public struct Limits: Sendable {
        public var flushInterval: Duration
        public var batchSize: Int
        /// A month file stops growing past this: a runaway loop must not fill the disk.
        public var maxFileBytes: Int
        /// Events of one kind kept per UTC day; the rest are counted in a `journal.dropped` line.
        public var dailyKindCap: Int
        /// Raw events older than this are pruned; their day's summary stays.
        public var rawRetentionDays: Int
        /// How often the session marker's `lastSeenAt` is refreshed while nothing else is written.
        public var heartbeat: TimeInterval

        public init(flushInterval: Duration = .seconds(10), batchSize: Int = 200, maxFileBytes: Int = 32 << 20,
                    dailyKindCap: Int = 5_000, rawRetentionDays: Int = 30, heartbeat: TimeInterval = 300) {
            self.flushInterval = flushInterval
            self.batchSize = batchSize
            self.maxFileBytes = maxFileBytes
            self.dailyKindCap = dailyKindCap
            self.rawRetentionDays = rawRetentionDays
            self.heartbeat = heartbeat
        }
    }

    private enum Command: Sendable {
        case event(JournalEvent)
        case flush(CheckedContinuation<Void, Never>?)
    }

    public nonisolated let log: JournalLog
    private let limits: Limits
    private let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Command>.Continuation
    private var buffer: [JournalEvent] = []
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var fullMonths: Set<String> = []
    /// Events kept today, by kind, and dropped past the cap.
    private var day = ""
    private var kept: [JournalEvent.Kind: Int] = [:]
    private var dropped: [JournalEvent.Kind: Int] = [:]
    private var session: JournalSession?
    private var sessionWrittenAt = Date.distantPast
    private let now: @Sendable () -> Date

    /// `ticks` drives the periodic flush (a clock by default); `now` is the clock for the day's rollover. Tests
    /// hand in their own.
    public init(log: JournalLog, limits: Limits = Limits(), ticks: AsyncStream<Void>? = nil,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.log = log
        self.limits = limits
        self.now = now
        self.ticks = ticks ?? UsageRecorder.ticks(every: limits.flushInterval)
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        self.continuation = continuation
        Task { await self.start(stream) }
    }

    deinit {
        continuation.finish()
        consumer?.cancel()
        ticker?.cancel()
    }

    private func start(_ stream: AsyncStream<Command>) {
        consumer = Task { [weak self] in
            for await command in stream { await self?.handle(command) }
        }
        let ticks = ticks
        let continuation = continuation
        ticker = Task {
            for await _ in ticks { continuation.yield(.flush(nil)) }
        }
    }

    // MARK: Sending

    public nonisolated func record(_ event: JournalEvent) {
        continuation.yield(.event(event))
    }

    /// Writes everything queued before this call.
    public func flush() async {
        await withCheckedContinuation { continuation.yield(.flush($0)) }
    }

    // MARK: Session

    /// Opens this session's marker and returns the previous one, as it was left. Also summarizes the days before
    /// today and prunes old raw events: launch is when a day nobody saw end gets its summary.
    public func beginSession(version: String) -> JournalSession? {
        let previous = JournalSession.read(log.sessionURL)
        let started = now()
        session = JournalSession(version: version, startedAt: started)
        session?.write(log.sessionURL)
        sessionWrittenAt = started
        housekeeping(at: started)
        return previous
    }

    /// Closes the marker after writing what is queued. The last thing the app does with the journal.
    public func endSession(reason: StopReason) async {
        await flush()
        guard var closing = session else { return }
        let stopped = now()
        closing.stoppedAt = stopped
        closing.lastSeenAt = stopped
        closing.stopReason = reason
        closing.write(log.sessionURL)
        session = closing
    }

    /// How long this session has run, for `app.stop`.
    public func sessionLength() -> TimeInterval {
        session.map { now().timeIntervalSince($0.startedAt) } ?? 0
    }

    // MARK: Handling

    private func handle(_ command: Command) {
        switch command {
        case .event(let event):
            rollOver(to: event.day, at: event.at)
            guard kept[event.kind, default: 0] < limits.dailyKindCap else {
                dropped[event.kind, default: 0] += 1
                return
            }
            kept[event.kind, default: 0] += 1
            buffer.append(event)
            if buffer.count >= limits.batchSize { write() }
        case .flush(let waiter):
            let current = now()
            rollOver(to: JournalEvent.day(of: current), at: current)
            write()
            waiter?.resume()
        }
    }

    /// A new UTC day: what was dropped yesterday is counted, then yesterday is summarized.
    private func rollOver(to next: String, at date: Date) {
        guard next != day else { return }
        let first = day.isEmpty
        noteDropped(at: date)
        day = next
        kept = [:]
        guard !first else { return }
        write()
        housekeeping(at: date)
    }

    private func noteDropped(at date: Date) {
        // Dated in the day the events were dropped, so its summary counts them.
        let lastMoment = JournalLog.utc.startOfDay(for: date).addingTimeInterval(-0.001)
        for (kind, count) in dropped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            buffer.append(JournalEvent(at: lastMoment, kind: .journalDropped, name: kind.rawValue, count: count))
        }
        dropped = [:]
    }

    private func housekeeping(at date: Date) {
        log.summarizePastDays(now: date)
        log.prune(before: date.addingTimeInterval(-Double(limits.rawRetentionDays) * 86_400))
    }

    private func write() {
        heartbeat()
        guard !buffer.isEmpty else { return }
        let events = buffer
        buffer.removeAll(keepingCapacity: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: log.directory, withIntermediateDirectories: true)
        var byFile: [URL: Data] = [:]
        var order: [URL] = []
        for event in events {
            guard let line = try? event.line() else { continue }
            let url = log.fileURL(for: event.at)
            if byFile[url] == nil { order.append(url) }
            byFile[url, default: Data()].append(line)
            byFile[url, default: Data()].append(UInt8(ascii: "\n"))
        }
        for url in order {
            guard let data = byFile[url], !fullMonths.contains(url.lastPathComponent) else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size + data.count <= limits.maxFileBytes else {
                fullMonths.insert(url.lastPathComponent)
                Log.app.notice("journal \(url.lastPathComponent, privacy: .public) is full; dropping events until next month")
                continue
            }
            JournalLog.append(data, to: url, fileManager: fileManager)
        }
    }

    /// Keeps `lastSeenAt` recent enough to date a crash, without a write on every flush.
    private func heartbeat() {
        let current = now()
        guard var open = session, open.stoppedAt == nil, current.timeIntervalSince(sessionWrittenAt) >= limits.heartbeat else { return }
        open.lastSeenAt = current
        open.write(log.sessionURL)
        session = open
        sessionWrittenAt = current
    }
}

/// The process-wide entry point, for code that cannot be handed a recorder: `gh` calls, the hook socket, the app's
/// models. Nothing is recorded until the app installs one, so tests and the command-line tools write nothing.
public enum Journal {
    private static let recorder = Mutex<JournalRecorder?>(nil)

    public static func install(_ journal: JournalRecorder?) {
        recorder.withLock { $0 = journal }
    }

    public static var current: JournalRecorder? {
        recorder.withLock { $0 }
    }

    public static func record(_ event: JournalEvent) {
        current?.record(event)
    }

    /// Times `body` and records the event `make` builds from its result and the seconds it took.
    public static func timed<T>(_ body: () async throws -> T,
                                record make: (Result<T, any Error>, TimeInterval) -> JournalEvent) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let value = try await body()
            record(make(.success(value), (ContinuousClock.now - start).timeInterval))
            return value
        } catch {
            record(make(.failure(error), (ContinuousClock.now - start).timeInterval))
            throw error
        }
    }
}

private extension Duration {
    /// Seconds as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
