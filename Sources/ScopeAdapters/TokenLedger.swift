import Foundation
import ScopeCore

/// The tokens each thread's agent consumed, summed from its Claude Code transcripts (`TranscriptUsage`), with where
/// each transcript was last read. Pure: `TokenLedgerStore` does the reading and the saving.
///
/// Kept apart from `ThreadActivity`, which holds only the latest transcript and goes with its thread: a session
/// cleared or resumed writes a new transcript, and an orchestrator closes threads all day, both of which would make
/// the meter undercount. Here a thread keeps every transcript it ever had, and stays after it is closed — its totals
/// for `summary` for `totalRetention`, its recent calls for the rolling windows for `windowRetention`.
public struct TokenLedger: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// How long calls are kept by the minute: the longest window (7 days) and a day of slack for time zones.
    public static let windowRetention: TimeInterval = 8 * 86_400
    /// How long a thread no call came from is remembered at all.
    public static let totalRetention: TimeInterval = 90 * 86_400

    /// Calls of one model in one minute.
    public struct Bucket: Codable, Sendable, Equatable {
        /// Minutes since 1970.
        public var minute: Int
        public var model: String
        public var counts: TokenCounts

        public init(minute: Int, model: String, counts: TokenCounts) {
            self.minute = minute
            self.model = model
            self.counts = counts
        }

        public var start: Date { Date(timeIntervalSince1970: TimeInterval(minute) * 60) }
    }

    public struct Thread: Codable, Sendable, Equatable {
        /// What the thread belongs to, as of the last time it was seen open: kept once it is closed.
        public var title: String
        public var scope: String
        public var task: String?
        /// Every call since the thread's first transcript was read.
        public var total: TokenCounts
        public var lastAt: Date?
        /// Calls within `windowRetention`, oldest first.
        public var buckets: [Bucket]
        /// Message ids already counted, with the minute of each, kept as long as the buckets: a response is written as
        /// several lines, and a forked subagent's transcript can repeat its parent's messages.
        public var seen: [String: Int]

        public init(title: String, scope: String, task: String? = nil, total: TokenCounts = .zero, lastAt: Date? = nil,
                    buckets: [Bucket] = [], seen: [String: Int] = [:]) {
            self.title = title
            self.scope = scope
            self.task = task
            self.total = total
            self.lastAt = lastAt
            self.buckets = buckets
            self.seen = seen
        }
    }

    public var version: Int
    /// Transcript path → the thread it counts for and the byte offset read up to.
    public var files: [String: Cursor]
    /// Thread id → its usage.
    public var threads: [String: Thread]

    public struct Cursor: Codable, Sendable, Equatable {
        public var thread: String
        public var offset: UInt64

        public init(thread: String, offset: UInt64 = 0) {
            self.thread = thread
            self.offset = offset
        }
    }

    public init(files: [String: Cursor] = [:], threads: [String: Thread] = [:]) {
        version = Self.currentVersion
        self.files = files
        self.threads = threads
    }

    /// Notes what `thread` belongs to now; creates it if new.
    public mutating func attribute(thread id: String, title: String, scope: String, task: String?) {
        var thread = threads[id] ?? Thread(title: title, scope: scope, task: task)
        thread.title = title
        thread.scope = scope
        thread.task = task
        threads[id] = thread
    }

    /// Adds the calls not counted yet to `thread`, which `attribute` must have created. Returns whether anything was.
    @discardableResult
    public mutating func record(_ entries: [TranscriptUsageEntry], thread id: String) -> Bool {
        guard var thread = threads[id] else { return false }
        var changed = false
        for entry in entries {
            let minute = Int((entry.at.timeIntervalSince1970 / 60).rounded(.down))
            guard thread.seen[entry.id] == nil else { continue }
            thread.seen[entry.id] = minute
            thread.total += entry.counts
            thread.lastAt = max(thread.lastAt ?? entry.at, entry.at)
            // Entries come in file order, nearly always the newest minute: look from the end, a few buckets back.
            if let index = thread.buckets.indices.reversed().prefix(8).first(where: {
                thread.buckets[$0].minute == minute && thread.buckets[$0].model == entry.model
            }) {
                thread.buckets[index].counts += entry.counts
            } else {
                let bucket = Bucket(minute: minute, model: entry.model, counts: entry.counts)
                let at = thread.buckets.lastIndex(where: { $0.minute <= minute }).map { $0 + 1 } ?? 0
                thread.buckets.insert(bucket, at: at)
            }
            changed = true
        }
        if changed { threads[id] = thread }
        return changed
    }

    /// Drops calls past `windowRetention`, and threads (with their transcripts) past `totalRetention`.
    public mutating func prune(now: Date) {
        let windowCut = Int(((now.timeIntervalSince1970 - Self.windowRetention) / 60).rounded(.down))
        let totalCut = now.addingTimeInterval(-Self.totalRetention)
        for (id, var thread) in threads {
            if let last = thread.lastAt, last < totalCut {
                threads[id] = nil
                continue
            }
            let before = (thread.buckets.count, thread.seen.count)
            thread.buckets.removeAll { $0.minute < windowCut }
            thread.seen = thread.seen.filter { $0.value >= windowCut }
            if before != (thread.buckets.count, thread.seen.count) { threads[id] = thread }
        }
        files = files.filter { threads[$0.value.thread] != nil }
    }

    // MARK: Reading it

    /// The snapshot every view and `scope list` reads: windows ending at `now`, "today" in `calendar`'s time zone.
    public func snapshot(now: Date, calendar: Calendar) -> TokenUsageSnapshot {
        let bounds = TokenWindows.Bounds(now: now, calendar: calendar)
        var all = TokenWindows()
        var byThread: [String: TokenUsageSnapshot.Row] = [:]
        var byTask: [String: TokenUsageSnapshot.Row] = [:]
        var byScope: [String: TokenUsageSnapshot.Row] = [:]
        for (id, thread) in threads {
            let windows = TokenWindows(thread.buckets, bounds: bounds)
            all += windows
            byThread[id] = .init(id: id, title: thread.title, scope: thread.scope, task: thread.task,
                                 windows: windows, total: thread.total, lastAt: thread.lastAt)
            if let task = thread.task {
                byTask[task, default: .init(id: task, title: task, scope: thread.scope, task: task)].add(windows, thread.total, thread.lastAt)
            }
            byScope[thread.scope, default: .init(id: thread.scope, title: thread.scope, scope: thread.scope)].add(windows, thread.total, thread.lastAt)
        }
        return TokenUsageSnapshot(at: now, all: all, threads: byThread, tasks: byTask, scopes: byScope)
    }
}

/// Tokens consumed over the three rolling windows the meter shows. A subscription's limits are counted over five hours
/// and a week; "today" is the calendar day, for reading alongside a summary.
public struct TokenWindows: Sendable, Equatable {
    public var fiveHours = TokenWindow()
    public var today = TokenWindow()
    public var sevenDays = TokenWindow()

    public init() {}

    public struct Bounds: Sendable, Equatable {
        public var fiveHours: Int
        public var today: Int
        public var sevenDays: Int

        /// In minutes since 1970, each included. A bucket is a minute; one that began before the cut is left out.
        public init(now: Date, calendar: Calendar) {
            func minute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.up)) }
            fiveHours = minute(now.addingTimeInterval(-5 * 3600))
            today = minute(calendar.startOfDay(for: now))
            sevenDays = minute(now.addingTimeInterval(-7 * 86_400))
        }
    }

    public init(_ buckets: [TokenLedger.Bucket], bounds: Bounds) {
        for bucket in buckets {
            if bucket.minute >= bounds.sevenDays { sevenDays.add(bucket) }
            if bucket.minute >= bounds.today { today.add(bucket) }
            if bucket.minute >= bounds.fiveHours { fiveHours.add(bucket) }
        }
    }

    public static func += (lhs: inout TokenWindows, rhs: TokenWindows) {
        lhs.fiveHours += rhs.fiveHours
        lhs.today += rhs.today
        lhs.sevenDays += rhs.sevenDays
    }
}

/// Tokens over one window, and by model for whoever prices them.
public struct TokenWindow: Sendable, Equatable {
    public var counts = TokenCounts.zero
    public var byModel: [String: TokenCounts] = [:]

    public init(counts: TokenCounts = .zero, byModel: [String: TokenCounts] = [:]) {
        self.counts = counts
        self.byModel = byModel
    }

    mutating func add(_ bucket: TokenLedger.Bucket) {
        counts += bucket.counts
        byModel[bucket.model, default: .zero] += bucket.counts
    }

    public static func += (lhs: inout TokenWindow, rhs: TokenWindow) {
        lhs.counts += rhs.counts
        for (model, counts) in rhs.byModel { lhs.byModel[model, default: .zero] += counts }
    }
}

/// `TokenLedger` summed per thread, task and scope at one moment.
public struct TokenUsageSnapshot: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var scope: String
        public var task: String?
        public var windows = TokenWindows()
        /// Since the first call Scope read, within `TokenLedger.totalRetention`.
        public var total = TokenCounts.zero
        public var lastAt: Date?

        public init(id: String, title: String, scope: String, task: String? = nil, windows: TokenWindows = TokenWindows(),
                    total: TokenCounts = .zero, lastAt: Date? = nil) {
            self.id = id
            self.title = title
            self.scope = scope
            self.task = task
            self.windows = windows
            self.total = total
            self.lastAt = lastAt
        }

        mutating func add(_ windows: TokenWindows, _ total: TokenCounts, _ lastAt: Date?) {
            self.windows += windows
            self.total += total
            if let lastAt { self.lastAt = max(self.lastAt ?? lastAt, lastAt) }
        }
    }

    public var at: Date
    public var all: TokenWindows
    /// Keyed by thread id, task id and scope id.
    public var threads: [String: Row]
    public var tasks: [String: Row]
    public var scopes: [String: Row]

    public init(at: Date = .distantPast, all: TokenWindows = TokenWindows(), threads: [String: Row] = [:],
                tasks: [String: Row] = [:], scopes: [String: Row] = [:]) {
        self.at = at
        self.all = all
        self.threads = threads
        self.tasks = tasks
        self.scopes = scopes
    }

    public static let empty = TokenUsageSnapshot()

    /// The threads that consumed the most over the last five hours, then the last seven days.
    public func topThreads(_ limit: Int) -> [Row] {
        Array(threads.values
            .filter { !$0.windows.sevenDays.counts.isZero }
            .sorted { ($0.windows.fiveHours.counts.total, $0.windows.sevenDays.counts.total, $0.id)
                    > ($1.windows.fiveHours.counts.total, $1.windows.sevenDays.counts.total, $1.id) }
            .prefix(limit))
    }
}

/// Owner of `<home>/tokens.json` — beside the usage log's `usage/` folder rather than in it, so clearing that log
/// never takes the counts with it — and the only reader of transcripts: one actor, so a scan triggered by a turn
/// ending and one by the timer never read the same bytes twice. Offsets and totals are saved in one file, so a crash
/// between the two cannot count a call twice.
public actor TokenLedgerStore {
    /// A thread whose transcripts count, as the app knows it now.
    public struct Source: Sendable, Equatable {
        public var thread: String
        public var title: String
        public var scope: String
        public var task: String?
        public var transcript: String

        public init(thread: String, title: String, scope: String, task: String?, transcript: String) {
            self.thread = thread
            self.title = title
            self.scope = scope
            self.task = task
            self.transcript = transcript
        }
    }

    public nonisolated let url: URL
    private var ledger: TokenLedger?

    public init(home: URL) {
        url = home.appending(path: "tokens.json", directoryHint: .notDirectory)
    }

    /// Reads what each source's transcripts (and its subagents') gained since the last scan, saves the ledger when
    /// that changed it, and returns the totals as of `now`.
    public func scan(_ sources: [Source], now: Date = .now, calendar: Calendar = .current) -> TokenUsageSnapshot {
        var ledger = self.ledger ?? load()
        let before = ledger
        for source in sources {
            ledger.attribute(thread: source.thread, title: source.title, scope: source.scope, task: source.task)
            let main = URL(fileURLWithPath: source.transcript)
            for file in [main] + TranscriptUsage.subagentTranscripts(of: main) {
                let path = file.path
                // A resumed session goes on in its transcript: what was read stays with the thread that read it, what
                // comes next counts for the thread reading it now, from where the other stopped.
                var cursor = ledger.files[path] ?? .init(thread: source.thread)
                cursor.thread = source.thread
                guard let size = Self.size(of: path), size != cursor.offset else { continue }
                do {
                    let read = try TranscriptUsage.read(file, from: cursor.offset)
                    ledger.record(read.entries, thread: source.thread)
                    cursor.offset = read.offset
                    ledger.files[path] = cursor
                } catch {
                    Log.threads.error("transcript \(path) unreadable: \(String(describing: error))")
                }
            }
        }
        // A thread whose transcript never had a call (a session never prompted) is kept only while it is open.
        let open = Set(sources.map(\.thread))
        ledger.threads = ledger.threads.filter { $0.value.lastAt != nil || open.contains($0.key) }
        ledger.prune(now: now)
        if ledger != before { save(ledger) }
        self.ledger = ledger
        return ledger.snapshot(now: now, calendar: calendar)
    }

    /// The saved totals, without reading any transcript.
    public func snapshot(now: Date = .now, calendar: Calendar = .current) -> TokenUsageSnapshot {
        let ledger = self.ledger ?? load()
        self.ledger = ledger
        return ledger.snapshot(now: now, calendar: calendar)
    }

    /// An unreadable or other-version file starts the ledger over: transcripts are read again from their start, and
    /// the windows are right again after one scan.
    private func load() -> TokenLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? Self.decoder.decode(TokenLedger.self, from: data),
              ledger.version == TokenLedger.currentVersion else { return TokenLedger() }
        return ledger
    }

    private func save(_ ledger: TokenLedger) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(ledger).write(to: url, options: .atomic)
        } catch {
            Log.threads.error("token ledger write failed: \(String(describing: error))")
        }
    }

    private static func size(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    // Compact, unlike the other stores: the file holds a week of per-minute buckets and is rewritten on each scan.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
