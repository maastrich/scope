import Foundation
import Synchronization

/// A clock that moves only when the test says so.
///
/// A `Debouncer` or `Throttle` built on it never fires on its own: its timer parks here until `advance(by:)`
/// carries the clock past the deadline. A test can then let the real world (FSEvents, vnode sources, a store's
/// writes) deliver whatever it delivers, in however many batches a loaded machine spreads it over, and only
/// then decide that the delay has elapsed — the assertion is about coalescing, no longer about whether the
/// runner managed to run the burst inside the window.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they could park (the cancellation handler ran first).
        var cancelled: Set<UInt64> = []
        /// Every sleep that ever parked: how many times a timer was (re)armed.
        var armed = 0
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Timers parked right now.
    var sleeping: Int { state.withLock { $0.sleepers.count } }

    /// How many timers were armed since the clock was made (a re-armed debounce counts again).
    var armed: Int { state.withLock { $0.armed } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case due, parked, cancelled }
                let outcome = state.withLock { state -> Outcome in
                    if state.cancelled.remove(id) != nil { return .cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    state.armed += 1
                    return .parked
                }
                switch outcome {
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every timer whose deadline is now past, earliest first.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits (in real time) until at least one timer is parked, then until no new timer has been armed for
    /// `quiet`: the events of one burst have all reached the debouncer, however the system batched them.
    /// `false` when nothing was armed within `timeout`.
    func settle(quiet: Duration = .milliseconds(300), timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while sleeping == 0 {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        while true {
            let before = armed
            try? await Task.sleep(for: quiet)
            if armed == before { return true }
        }
    }
}

/// Polls `condition` (in real time) every 10 ms until it holds or `timeout` elapses.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
