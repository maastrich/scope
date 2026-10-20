import Foundation
import Synchronization

/// Watches one folder of state documents (`threads/`, `tasks/`) and says, once per burst, that something in it
/// changed. Which files, and whether the app itself wrote them, is the store's business (`RecordLedger`): this
/// only coalesces the file-system events and drops the ones no document is behind.
///
/// FSEvents rather than a vnode source on the directory: the latter only fires when an entry is added, removed
/// or renamed (an atomic write), and misses an editor rewriting a file in place. File-level FSEvents see both.
/// The temp file of an atomic write shows up too, under its own name, which `names` lets through only when it
/// looks like a document.
public final class StateFolderWatcher: Sendable {
    private let folder: URL
    private let names: @Sendable (String) -> Bool
    private let debouncer: Debouncer
    private let state = Mutex<(watcher: FSEventsWatcher?, pump: Task<Void, Never>?)>((nil, nil))

    /// - Parameters:
    ///   - folder: the directory, watched for its direct entries (deeper paths are ignored).
    ///   - names: which file names count; the rest never wakes the consumer.
    ///   - delay: silence required after the last event before `onChange` runs.
    ///   - clock: what measures that silence; tests drive one by hand.
    ///   - onChange: runs once per burst, off the main actor.
    public init(folder: URL, names: @escaping @Sendable (String) -> Bool, delay: Duration = .milliseconds(300),
                clock: any Clock<Duration> = ContinuousClock(), onChange: @escaping @Sendable () async -> Void) {
        self.folder = folder
        self.names = names
        debouncer = Debouncer(delay: delay, clock: clock, action: onChange)
    }

    deinit { stop() }

    /// Starts watching; the folder is created if missing (FSEvents needs it to exist). No-op when running.
    public func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = FSEventsWatcher(paths: [folder], latency: 0.2)
        let (debouncer, names, folder) = (debouncer, names, folder)
        // FSEvents reports real paths (`/private/var/…` for `/var/…`, which Foundation's own resolver keeps
        // short): both spellings of the folder count.
        let spellings = Set(ProcessSweep.spellings(folder))
        let started = state.withLock { state -> Bool in
            guard state.watcher == nil else { return false }
            state.watcher = watcher
            state.pump = Task.detached(priority: .utility) {
                for await batch in watcher.events {
                    let relevant = batch.events.contains { event in
                        if event.mustRescan { return true }
                        let url = URL(fileURLWithPath: event.path)
                        guard spellings.contains(url.deletingLastPathComponent().path) else { return false }
                        return names(url.lastPathComponent)
                    }
                    if relevant { await debouncer.fire() }
                }
            }
            return true
        }
        guard started else { return }
        watcher.start()
        if !watcher.isRunning {
            Log.fs.error("FSEvents stream could not be started for \(folder.path, privacy: .public)")
        }
    }

    /// Stops watching and drops a pending run. Idempotent.
    public func stop() {
        let (watcher, pump) = state.withLock { state -> (FSEventsWatcher?, Task<Void, Never>?) in
            defer { state.watcher = nil; state.pump = nil }
            return (state.watcher, state.pump)
        }
        pump?.cancel()
        watcher?.stop()
        let debouncer = debouncer
        Task { await debouncer.cancel() }
    }

    /// Runs a pending `onChange` now (tests, shutdown).
    public func flush() async {
        await debouncer.flush()
    }
}

/// Watches one document (`config.json`) and says, once per burst, that it changed.
///
/// Two vnode sources: one on the file, for a rewrite in place, and one on its directory, for the atomic write
/// (a rename over the path, which the file's own source sees as `.rename`/`.delete` and then goes blind) and
/// for the file appearing or disappearing. After any event the file source is re-armed on the path, so the new
/// inode is watched next. Nothing recursive: a vnode source on the home never hears about the sandboxes.
public final class StateFileWatcher: Sendable {
    private let file: URL
    private let debouncer: Debouncer
    private let queue = DispatchQueue(label: "dev.scope.statefile", qos: .utility)
    private let state = Mutex<Sources?>(nil)

    private struct Sources {
        var directory: DispatchSourceFileSystemObject?
        var file: DispatchSourceFileSystemObject?
    }

    public init(file: URL, delay: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
                onChange: @escaping @Sendable () async -> Void) {
        self.file = file
        debouncer = Debouncer(delay: delay, clock: clock, action: onChange)
    }

    deinit { stop() }

    /// Starts watching. The directory must exist; the file may not. No-op when running.
    ///
    /// Both sources are armed before this returns: a write that follows `start()` is never missed.
    public func start() {
        let started = state.withLock { state -> Bool in
            guard state == nil else { return false }
            state = Sources()
            return true
        }
        guard started else { return }
        queue.sync { [self] in
            arm(directory: true)
            arm(directory: false)
        }
    }

    /// Stops watching and drops a pending run. Idempotent.
    public func stop() {
        let sources = state.withLock { state -> Sources? in
            defer { state = nil }
            return state
        }
        sources?.directory?.cancel()
        sources?.file?.cancel()
        let debouncer = debouncer
        Task { await debouncer.cancel() }
    }

    /// Runs a pending `onChange` now (tests, shutdown).
    public func flush() async {
        await debouncer.flush()
    }

    /// On `queue`. Opens the path and points a source at it; a path that cannot be opened (no file yet) is
    /// left for the directory source to notice.
    private func arm(directory: Bool) {
        let path = directory ? file.deletingLastPathComponent().path : file.path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let mask: DispatchSource.FileSystemEvent = directory ? [.write] : [.write, .extend, .delete, .rename, .revoke, .attrib]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        let debouncer = debouncer
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            Task { await debouncer.fire() }
            // The directory changed: the file may be a new inode now (atomic write) or gone. Re-arm the file
            // source either way; a file source whose inode went away is useless.
            if directory || !event.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.rearmFile()
            }
        }
        source.setCancelHandler { close(descriptor) }
        let installed = state.withLock { state -> Bool in
            guard state != nil else { return false }
            if directory { state?.directory?.cancel(); state?.directory = source } else { state?.file?.cancel(); state?.file = source }
            return true
        }
        guard installed else {
            source.setEventHandler {}
            source.cancel()
            return
        }
        source.resume()
    }

    private func rearmFile() {
        guard state.withLock({ $0 != nil }) else { return }
        arm(directory: false)
    }
}
