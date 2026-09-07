import CoreServices   // FSEvents lives here, not in Foundation.
import Foundation

/// One batch of FSEvents, as coalesced by the system over the stream's latency window.
public struct FSEventBatch: Sendable {
    /// One path with its flags. Flags accumulate over the latency window (a file created then modified
    /// carries both bits).
    public struct Event: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags
        public let id: FSEventStreamEventId

        public init(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId) {
            self.path = path
            self.flags = flags
            self.id = id
        }

        public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
        /// Events were dropped: the whole subtree must be rescanned.
        public var mustRescan: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }
        /// The watched root itself was moved or deleted (requires the watch-root flag, always set here).
        public var rootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }
        public var created: Bool { has(kFSEventStreamEventFlagItemCreated) }
        public var removed: Bool { has(kFSEventStreamEventFlagItemRemoved) }
        public var renamed: Bool { has(kFSEventStreamEventFlagItemRenamed) }
        public var modified: Bool { has(kFSEventStreamEventFlagItemModified) }

        private func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
    }

    public let events: [Event]
    public var paths: [String] { events.map(\.path) }

    public init(events: [Event]) {
        self.events = events
    }
}

/// Swift 6-safe wrapper around `FSEventStreamCreate`, delivering batches on an `AsyncStream`.
///
/// - The C callback cannot capture Swift context: `self` travels through `FSEventStreamContext.info`
///   unretained, so the watcher must outlive the stream — `deinit` stops it.
/// - Events are delivered on a private serial queue (`FSEventStreamSetDispatchQueue`); the only mutable
///   field is touched on that queue, which is why the class is `@unchecked Sendable`.
/// - Paths arrive resolved (`/private/tmp/…` even when `/tmp/…` was registered); callers compare against
///   both forms. The stream also reports temp files from atomic writes and everything under `.git/`:
///   filter and debounce downstream (see ``ScopeEventFilter``).
/// - The stream is one-shot: `stop()` finishes the `events` stream. Create a new watcher to watch again.
public final class FSEventsWatcher: @unchecked Sendable {
    /// Batches of events, in delivery order. Finishes when the watcher stops.
    public let events: AsyncStream<FSEventBatch>

    private let continuation: AsyncStream<FSEventBatch>.Continuation
    private let queue = DispatchQueue(label: "dev.scope.fsevents", qos: .utility)
    private let paths: [String]
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?   // only touched on `queue`

    /// - Parameters:
    ///   - paths: folders to watch recursively.
    ///   - latency: coalescing window in seconds; the first event of a burst is delivered without delay.
    public init(paths: [URL], latency: CFTimeInterval = 0.5) {
        self.paths = paths.map(\.path)
        self.latency = latency
        (events, continuation) = AsyncStream.makeStream(of: FSEventBatch.self, bufferingPolicy: .bufferingNewest(64))
    }

    deinit {
        // `deinit` may run on any thread; the queue is serial so this is safe.
        queue.sync { stopOnQueue() }
    }

    /// `true` between a successful `start()` and `stop()`.
    public var isRunning: Bool { queue.sync { stream != nil } }

    /// Creates and starts the stream. A second call is a no-op. Silent on failure: check ``isRunning``.
    public func start() {
        queue.sync { startOnQueue() }
    }

    /// Stops and releases the stream, finishing ``events``. Idempotent.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    private func startOnQueue() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents      // per-file events, not just "something in this folder"
            | kFSEventStreamCreateFlagUseCFTypes    // eventPaths is a CFArray<CFString>
            | kFSEventStreamCreateFlagNoDefer       // deliver the first event immediately, then coalesce
            | kFSEventStreamCreateFlagWatchRoot)    // report the root being moved or deleted (RootChanged)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    private func stopOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)   // FSEventStreamRef is an OpaquePointer: no ARC, release by hand
        self.stream = nil
        continuation.finish()
    }

    fileprivate func deliver(_ batch: FSEventBatch) {
        continuation.yield(batch)
    }
}

/// Free function of the exact `FSEventStreamCallback` type; no captures allowed.
private let fsEventsCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    // With kFSEventStreamCreateFlagUseCFTypes, `eventPaths` is a CFArrayRef of CFStringRef.
    guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }
    var events: [FSEventBatch.Event] = []
    events.reserveCapacity(count)
    for index in 0..<min(count, paths.count) {
        events.append(.init(path: paths[index], flags: eventFlags[index], id: eventIds[index]))
    }
    watcher.deliver(FSEventBatch(events: events))
}
