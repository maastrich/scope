import Foundation

/// Counting semaphore for structured concurrency, used to cap the number of concurrent
/// subprocesses (the git fan-out guard).
///
/// Waiters are served in FIFO order. `acquire()` is not cancellable: a waiting task keeps its
/// place in the queue and returns once a permit is handed to it.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a semaphore with `limit` permits (`limit` is clamped to at least 1).
    public init(limit: Int) {
        available = max(1, limit)
    }

    /// Waits until a permit is available and takes it.
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Returns a permit. If a task is waiting, the permit is handed to it directly.
    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Runs `body` with a permit held; the permit is released when `body` returns or throws.
    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
