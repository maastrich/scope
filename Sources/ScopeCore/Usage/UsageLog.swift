import Foundation

/// The files under `SCOPE_HOME/usage/`: one `usage-YYYY-MM.jsonl` per month, and `registry.json`.
///
/// Months are counted in UTC so a file's name never depends on where the Mac was when it wrote it; the report filters
/// by date anyway.
public struct UsageLog: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<home>/usage`.
    public init(home: URL) {
        self.init(directory: home.appending(path: "usage", directoryHint: .isDirectory))
    }

    public var registryURL: URL { directory.appending(path: "registry.json", directoryHint: .notDirectory) }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `usage-2026-10.jsonl` for any date in October 2026 (UTC).
    public func fileURL(for date: Date) -> URL {
        let parts = Self.utc.dateComponents([.year, .month], from: date)
        let name = String(format: "usage-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The month a log file covers, as [start, end); `nil` for anything else in the folder.
    static func month(of url: URL) -> (Date, Date)? {
        let name = url.lastPathComponent
        guard name.hasPrefix("usage-"), name.hasSuffix(".jsonl") else { return nil }
        let parts = name.dropFirst("usage-".count).dropLast(".jsonl".count).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let start = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = utc.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// Every log file, oldest month first.
    public func files(fileManager: FileManager = .default) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Self.month(of: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The events in [since, until), in file order. A line that does not decode — cut short by a crash, written by a
    /// newer build — is skipped, never fatal.
    public func read(since: Date, until: Date, fileManager: FileManager = .default) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for url in files(fileManager: fileManager) {
            guard let (start, end) = Self.month(of: url), start < until, end > since,
                  let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let event = UsageEvent.decode(line: line), since <= event.at, event.at < until else { continue }
                events.append(event)
            }
        }
        return events
    }

    public func readRegistry() -> UsageRegistry {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(UsageRegistry.self, from: data) else { return UsageRegistry() }
        return registry
    }

    /// Removes the month files that ended before `cutoff`. A month that straddles it stays whole: the report reads by
    /// date, so the older half of it costs disk, not correctness.
    @discardableResult
    public func prune(before cutoff: Date, fileManager: FileManager = .default) -> [URL] {
        let expired = files(fileManager: fileManager).filter { url in Self.month(of: url).map { $0.1 <= cutoff } ?? false }
        for url in expired { try? fileManager.removeItem(at: url) }
        return expired
    }

    /// Every month file; the registry stays, since it says what exists rather than what was done.
    public func clear(fileManager: FileManager = .default) {
        for url in files(fileManager: fileManager) { try? fileManager.removeItem(at: url) }
    }
}

/// Batches usage events and appends them to the month's file off the main thread.
///
/// `record` and `register` are `nonisolated` and only yield into a stream, so a click costs the main thread an enqueue
/// and nothing else. One stream carries events, registrations, flushes and clears alike, which keeps them in the order
/// they were sent: a view's open and close, a clear and the click after it.
public actor UsageRecorder {
    public struct Limits: Sendable {
        /// How long events wait in memory before they are written.
        public var flushInterval: Duration
        /// Events held before a write happens anyway.
        public var batchSize: Int
        /// A month file stops growing past this; events beyond it are dropped. A runaway loop must not fill the disk.
        public var maxFileBytes: Int
        /// History older than this is pruned at launch.
        public var retentionDays: Int

        public init(flushInterval: Duration = .seconds(5), batchSize: Int = 200, maxFileBytes: Int = 8 << 20, retentionDays: Int = 180) {
            self.flushInterval = flushInterval
            self.batchSize = batchSize
            self.maxFileBytes = maxFileBytes
            self.retentionDays = retentionDays
        }
    }

    private enum Command: Sendable {
        case event(UsageEvent)
        case register([UsageElement])
        case enable(Bool)
        case flush(CheckedContinuation<Void, Never>?)
        case clear(CheckedContinuation<Void, Never>)
    }

    public nonisolated let log: UsageLog
    private let limits: Limits
    private let continuation: AsyncStream<Command>.Continuation
    private var buffer: [UsageEvent] = []
    private var registry: UsageRegistry
    private var registryDirty = false
    private var enabled: Bool
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Months whose file hit `maxFileBytes`, so the size is not read again for every batch.
    private var fullMonths: Set<String> = []

    public init(log: UsageLog, enabled: Bool = true, limits: Limits = Limits()) {
        self.log = log
        self.limits = limits
        self.enabled = enabled
        self.registry = log.readRegistry()
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
            for await command in stream {
                await self?.handle(command)
            }
        }
        let interval = limits.flushInterval
        let continuation = continuation
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                continuation.yield(.flush(nil))
            }
        }
    }

    // MARK: Sending

    /// Queues an event. Dropped (by the actor, in order) while recording is off.
    public nonisolated func record(_ event: UsageEvent) {
        continuation.yield(.event(event))
    }

    /// Queues elements for the registry. Registered whether or not recording is on: the registry is what exists.
    public nonisolated func register(_ elements: [UsageElement]) {
        guard !elements.isEmpty else { return }
        continuation.yield(.register(elements))
    }

    /// Turns recording on or off. Off drops what is still waiting to be written.
    public nonisolated func setEnabled(_ on: Bool) {
        continuation.yield(.enable(on))
    }

    /// Writes everything queued before this call. For quit, and before the report reads the files.
    public func flush() async {
        await withCheckedContinuation { continuation.yield(.flush($0)) }
    }

    /// Drops what is queued and deletes the history; everything queued before this call is gone with it.
    public func clear() async {
        await withCheckedContinuation { continuation.yield(.clear($0)) }
    }

    /// Prunes history past the retention period. Called at launch.
    public func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(limits.retentionDays) * 86_400)
        log.prune(before: cutoff)
    }

    // MARK: Handling

    private func handle(_ command: Command) {
        switch command {
        case .event(let event):
            guard enabled else { return }
            buffer.append(event)
            if buffer.count >= limits.batchSize { write() }
        case .register(let elements):
            if registry.merge(elements) { registryDirty = true }
        case .enable(let on):
            enabled = on
            if !on { buffer.removeAll() }
        case .flush(let waiter):
            write()
            waiter?.resume()
        case .clear(let waiter):
            buffer.removeAll()
            log.clear()
            fullMonths.removeAll()
            waiter.resume()
        }
    }

    private func write() {
        if registryDirty { writeRegistry() }
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
                Log.app.info("usage log \(url.lastPathComponent, privacy: .public) is full; dropping events until next month")
                continue
            }
            append(data, to: url, fileManager: fileManager)
        }
    }

    private func append(_ data: Data, to url: URL, fileManager: FileManager) {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func writeRegistry() {
        registryDirty = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(registry) else { return }
        try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
        try? data.write(to: log.registryURL, options: .atomic)
    }
}
