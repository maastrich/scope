import Foundation
import Synchronization

/// Watches one scope folder and turns raw FSEvents into coalesced ``ScopeChangeHint``s.
///
/// Pipeline: ``FSEventsWatcher`` → ``ScopeEventFilter/classify(_:root:depth:knownRepos:)`` →
/// rescan hints through a trailing-edge ``Debouncer`` (`rescanDelay`), touched-repo hints through a
/// leading + trailing ``Throttle`` (`factsInterval`). Filtering never runs on the main actor; only the
/// delivery of a hint hops there. Rescan and facts hints are delivered as separate calls.
///
/// `start()` / `stop()` are idempotent and the watcher can be restarted after a stop.
public final class ScopeWatcher: Sendable {
    private let core: Core
    private let debouncer: Debouncer
    private let throttle: Throttle
    private let latency: CFTimeInterval = 0.5

    /// - Parameters:
    ///   - root: the scope folder to watch (recursively).
    ///   - depth: the scope's discovery depth, used to decide which folder changes deserve a rescan.
    ///   - knownRepos: called once per batch; returns the relative paths of the repos currently shown.
    ///   - rescanDelay: silence required before a rescan hint is delivered.
    ///   - factsInterval: minimum spacing between two touched-repo deliveries.
    ///   - onChange: receives every non-empty hint on the main actor.
    public init(root: URL, depth: Int, knownRepos: @escaping @Sendable () async -> Set<String>,
                rescanDelay: Duration = .milliseconds(750), factsInterval: Duration = .seconds(2),
                onChange: @escaping @MainActor @Sendable (ScopeChangeHint) -> Void) {
        let core = Core(root: root, depth: depth, knownRepos: knownRepos, onChange: onChange)
        self.core = core
        self.debouncer = Debouncer(delay: rescanDelay) { await core.deliverRescan() }
        self.throttle = Throttle(minimumInterval: factsInterval) { await core.deliverFacts() }
    }

    deinit {
        stop()
    }

    /// Starts watching. No-op when already running.
    public func start() {
        let watcher = FSEventsWatcher(paths: [core.root], latency: latency)
        let (core, debouncer, throttle) = (core, debouncer, throttle)
        let started = core.state.withLock { state -> Bool in
            guard state.watcher == nil else { return false }
            state.watcher = watcher
            state.pump = Task.detached(priority: .utility) {
                for await batch in watcher.events {
                    let known = await core.knownRepos()
                    let hint = ScopeEventFilter.classify(batch, root: core.root, depth: core.depth, knownRepos: known)
                    if hint.needsRescan {
                        core.enqueue(rescan: hint)
                        await debouncer.fire()
                    }
                    if !hint.touchedRepos.isEmpty {
                        core.enqueue(facts: hint)
                        await throttle.fire()
                    }
                }
            }
            return true
        }
        guard started else { return }
        watcher.start()
        if !watcher.isRunning {
            Log.fs.error("FSEvents stream could not be started for \(core.root.path, privacy: .public)")
        }
    }

    /// Stops watching and drops pending hints. Idempotent.
    public func stop() {
        let (watcher, pump) = core.state.withLock { state -> (FSEventsWatcher?, Task<Void, Never>?) in
            defer {
                state.watcher = nil
                state.pump = nil
                state.pendingRescan = .none
                state.pendingFacts = .none
            }
            return (state.watcher, state.pump)
        }
        pump?.cancel()
        watcher?.stop()
        let (debouncer, throttle) = (debouncer, throttle)
        Task {
            await debouncer.cancel()
            await throttle.cancel()
        }
    }

    /// Delivers whatever is pending right now (manual refresh, shutdown), bypassing the timers.
    public func flush() async {
        await debouncer.flush()
        await core.deliverRescan()
        await throttle.cancel()
        await core.deliverFacts()
    }

    // MARK: - Core

    /// Mutable state and delivery, separated from the timers so the timer actions never capture the
    /// watcher itself (no retain cycle; `deinit` can stop everything).
    private final class Core: Sendable {
        struct State: Sendable {
            var watcher: FSEventsWatcher?
            var pump: Task<Void, Never>?
            var pendingRescan: ScopeChangeHint = .none
            var pendingFacts: ScopeChangeHint = .none
        }

        let root: URL
        let depth: Int
        let knownRepos: @Sendable () async -> Set<String>
        let onChange: @MainActor @Sendable (ScopeChangeHint) -> Void
        let state = Mutex(State())

        init(root: URL, depth: Int, knownRepos: @escaping @Sendable () async -> Set<String>,
             onChange: @escaping @MainActor @Sendable (ScopeChangeHint) -> Void) {
            self.root = root
            self.depth = depth
            self.knownRepos = knownRepos
            self.onChange = onChange
        }

        func enqueue(rescan hint: ScopeChangeHint) {
            let flagsOnly = ScopeChangeHint(rescan: hint.rescan, fullRescan: hint.fullRescan, rootChanged: hint.rootChanged)
            state.withLock { $0.pendingRescan = $0.pendingRescan.merged(with: flagsOnly) }
        }

        func enqueue(facts hint: ScopeChangeHint) {
            let reposOnly = ScopeChangeHint(touchedRepos: hint.touchedRepos)
            state.withLock { $0.pendingFacts = $0.pendingFacts.merged(with: reposOnly) }
        }

        func deliverRescan() async {
            let hint = state.withLock { state -> ScopeChangeHint in
                defer { state.pendingRescan = .none }
                return state.pendingRescan
            }
            guard !hint.isEmpty else { return }
            await onChange(hint)
        }

        func deliverFacts() async {
            let hint = state.withLock { state -> ScopeChangeHint in
                defer { state.pendingFacts = .none }
                return state.pendingFacts
            }
            guard !hint.isEmpty else { return }
            await onChange(hint)
        }
    }
}
