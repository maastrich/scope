import Foundation

/// The files under `SCOPE_HOME/logs/`: `events-YYYY-MM.jsonl` (raw, one per UTC month, kept `Limits.rawRetentionDays`),
/// `summary.jsonl` (one line per UTC day, kept) and `session.json` (the running session, for crash detection).
public struct JournalLog: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<home>/logs`.
    public init(home: URL) {
        self.init(directory: home.appending(path: "logs", directoryHint: .isDirectory))
    }

    public var summaryURL: URL { directory.appending(path: "summary.jsonl", directoryHint: .notDirectory) }
    public var sessionURL: URL { directory.appending(path: "session.json", directoryHint: .notDirectory) }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `events-2026-10.jsonl` for any date in October 2026 (UTC).
    public func fileURL(for date: Date) -> URL {
        let parts = Self.utc.dateComponents([.year, .month], from: date)
        let name = String(format: "events-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The month a raw file covers, as [start, end); `nil` for anything else in the folder.
    static func month(of url: URL) -> (Date, Date)? {
        let name = url.lastPathComponent
        guard name.hasPrefix("events-"), name.hasSuffix(".jsonl") else { return nil }
        let parts = name.dropFirst("events-".count).dropLast(".jsonl".count).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let start = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = utc.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// Every raw file, oldest month first.
    public func files(fileManager: FileManager = .default) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Self.month(of: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The events in [since, until), in file order. A line that does not decode is skipped.
    public func read(since: Date, until: Date, fileManager: FileManager = .default) -> [JournalEvent] {
        var events: [JournalEvent] = []
        for url in files(fileManager: fileManager) {
            guard let (start, end) = Self.month(of: url), start < until, end > since,
                  let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let event = JournalEvent.decode(line: line), since <= event.at, event.at < until else { continue }
                events.append(event)
            }
        }
        return events
    }

    /// The oldest event on disk.
    public func firstEventDate(fileManager: FileManager = .default) -> Date? {
        for url in files(fileManager: fileManager) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let first = data.split(separator: UInt8(ascii: "\n")).lazy.compactMap({ JournalEvent.decode(line: $0) }).first {
                return first.at
            }
        }
        return nil
    }

    /// Removes the raw events from before `cutoff`, as `UsageLog.prune` does. Summaries stay.
    public func prune(before cutoff: Date, fileManager: FileManager = .default) {
        for url in files(fileManager: fileManager) {
            guard let (start, end) = Self.month(of: url) else { continue }
            if end <= cutoff {
                try? fileManager.removeItem(at: url)
            } else if start < cutoff, let data = try? Data(contentsOf: url) {
                let lines = data.split(separator: UInt8(ascii: "\n"))
                let kept = lines.filter { JournalEvent.decode(line: $0).map { $0.at >= cutoff } ?? false }
                guard kept.count < lines.count else { continue }
                var rewritten = Data()
                for line in kept { rewritten.append(contentsOf: line); rewritten.append(UInt8(ascii: "\n")) }
                try? rewritten.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Summaries

    public func readSummaries() -> [JournalDaySummary] {
        guard let data = try? Data(contentsOf: summaryURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(JournalDaySummary.self, from: Data($0)) }
    }

    /// Writes a summary for every UTC day before `now`'s that has raw events and no summary yet. Returns the days added.
    ///
    /// A day is summarized once: events that arrive for it later (a clock moved back) stay in the raw file only.
    @discardableResult
    public func summarizePastDays(now: Date = .now, fileManager: FileManager = .default) -> [String] {
        let today = JournalEvent.day(of: now)
        let done = Set(readSummaries().map(\.day))
        guard let first = firstEventDate(fileManager: fileManager),
              let start = Self.utc.dateInterval(of: .day, for: first)?.start,
              let end = Self.utc.dateInterval(of: .day, for: now)?.start, start < end else { return [] }
        var byDay: [String: [JournalEvent]] = [:]
        for event in read(since: start, until: end, fileManager: fileManager) where event.day < today {
            byDay[event.day, default: []].append(event)
        }
        let added = byDay.keys.filter { !done.contains($0) }.sorted()
        guard !added.isEmpty else { return [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = Data()
        for day in added {
            guard let line = try? encoder.encode(JournalDaySummary(day: day, events: byDay[day] ?? [])) else { continue }
            lines.append(line)
            lines.append(UInt8(ascii: "\n"))
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        JournalLog.append(lines, to: summaryURL, fileManager: fileManager)
        return added
    }

    static func append(_ data: Data, to url: URL, fileManager: FileManager) {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// One UTC day of the journal condensed: what the raw file said, small enough to keep for years.
public struct JournalDaySummary: Codable, Sendable, Equatable {
    public struct Durations: Codable, Sendable, Equatable {
        public var count: Int
        public var p50: Double
        public var p90: Double
        public var max: Double
    }

    public struct TopProblem: Codable, Sendable, Equatable {
        public var name: String
        public var template: String?
        public var severity: String?
        public var cause: String?
        public var count: Int
    }

    public var day: String
    public var total: Int
    /// Events by kind.
    public var kinds: [String: Int]
    /// `"<kind> <outcome>"` → count, for kinds that carry an outcome.
    public var outcomes: [String: Int]
    /// `"<kind> <cause>"` → count.
    public var causes: [String: Int]
    /// Durations by kind, and by `"<kind> <name>"` for `control` and `gh`.
    public var durations: [String: Durations]
    /// The versions that ran that day.
    public var versions: [String]
    /// The ten most frequent problems.
    public var problems: [TopProblem]

    public init(day: String, events: [JournalEvent]) {
        self.day = day
        total = events.count
        var kinds: [String: Int] = [:], outcomes: [String: Int] = [:], causes: [String: Int] = [:]
        var seconds: [String: [Double]] = [:]
        var versions = Set<String>()
        var problems: [String: TopProblem] = [:]
        for event in events {
            let kind = event.kind.rawValue
            kinds[kind, default: 0] += 1
            if let outcome = event.outcome { outcomes["\(kind) \(outcome)", default: 0] += 1 }
            if let cause = event.cause { causes["\(kind) \(cause)", default: 0] += 1 }
            if let value = event.seconds {
                seconds[kind, default: []].append(value)
                if let name = event.name, event.kind == .control || event.kind == .gh {
                    seconds["\(kind) \(name)", default: []].append(value)
                }
            }
            if event.kind == .appStart, let version = event.version { versions.insert(version) }
            if event.kind == .problem {
                let key = event.name ?? JournalEvent.redacted
                problems[key, default: TopProblem(name: key, template: event.template, severity: event.severity,
                                                   cause: event.cause, count: 0)].count += 1
            }
        }
        self.kinds = kinds
        self.outcomes = outcomes
        self.causes = causes
        durations = seconds.mapValues(Self.durations)
        self.versions = versions.sorted()
        self.problems = Array(problems.values.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.prefix(10))
    }

    /// Nearest-rank percentiles.
    static func durations(_ values: [Double]) -> Durations {
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        return Durations(count: sorted.count, p50: rank(0.5), p90: rank(0.9), max: sorted.last ?? 0)
    }
}

/// `logs/session.json`: written when the app starts, closed when it quits. Found open at the next start, it says
/// the previous session ended without a quit.
public struct JournalSession: Codable, Sendable, Equatable {
    public var version: String
    public var startedAt: Date
    /// The last time the journal wrote anything: the best guess of when an unclosed session died.
    public var lastSeenAt: Date
    public var stoppedAt: Date?
    public var stopReason: StopReason?

    public init(version: String, startedAt: Date) {
        self.version = version
        self.startedAt = startedAt
        lastSeenAt = startedAt
    }

    /// How it ended, as the next launch reports it.
    public var end: SessionEnd {
        switch stopReason {
        case .update: .update
        case .quit, .powerOff: .clean
        case nil: .unclean
        }
    }

    /// Seconds it lasted, up to the quit or the last sign of life.
    public var length: TimeInterval { (stoppedAt ?? lastSeenAt).timeIntervalSince(startedAt) }

    static func read(_ url: URL) -> JournalSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageEvent.decoder.decode(JournalSession.self, from: data)
    }

    func write(_ url: URL) {
        guard let data = try? UsageEvent.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
