import Foundation

/// Trailing-edge debouncer: `action` runs once after `delay` of silence following the last `fire()`.
///
/// Used to coalesce FSEvents bursts into one rescan. A `fire()` that arrives while `action` is
/// running schedules another run after the current one.
public actor Debouncer {
    private let delay: Duration
    private let action: @Sendable () async -> Void
    private var pending = false
    private var generation: UInt64 = 0
    private var timer: Task<Void, Never>?

    public init(delay: Duration, action: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.action = action
    }

    /// Restarts the timer; `action` runs once after `delay` of silence.
    public func fire() {
        pending = true
        generation += 1
        let expected = generation
        timer?.cancel()
        timer = Task.detached { [delay] in
            try? await Task.sleep(for: delay)
            await self.timerFired(generation: expected)
        }
    }

    /// Drops any pending run.
    public func cancel() {
        pending = false
        generation += 1
        timer?.cancel()
        timer = nil
    }

    /// Runs `action` now if a run is pending (manual refresh, shutdown).
    public func flush() async {
        guard pending else { return }
        cancel()
        await action()
    }

    private func timerFired(generation expected: UInt64) async {
        guard expected == generation, pending else { return }
        pending = false
        timer = nil
        await action()
    }
}

/// Leading + trailing throttle: the first `fire()` runs `action` immediately, further fires within
/// `minimumInterval` are collapsed into at most one trailing run at the end of the interval.
///
/// Used to keep `git status` refreshes at most one per repo per interval.
public actor Throttle {
    private let minimumInterval: Duration
    private let action: @Sendable () async -> Void
    private var inCooldown = false
    private var trailingPending = false
    private var generation: UInt64 = 0
    private var cooldown: Task<Void, Never>?

    public init(minimumInterval: Duration, action: @escaping @Sendable () async -> Void) {
        self.minimumInterval = minimumInterval
        self.action = action
    }

    /// Leading edge runs immediately; at most one trailing run per interval.
    public func fire() {
        if inCooldown {
            trailingPending = true
            return
        }
        runNowAndStartCooldown()
    }

    /// Drops any pending trailing run and ends the current cooldown.
    public func cancel() {
        trailingPending = false
        inCooldown = false
        generation += 1
        cooldown?.cancel()
        cooldown = nil
    }

    private func runNowAndStartCooldown() {
        inCooldown = true
        generation += 1
        let expected = generation
        let action = self.action
        Task.detached {
            await action()
        }
        cooldown = Task.detached { [minimumInterval] in
            try? await Task.sleep(for: minimumInterval)
            await self.cooldownEnded(generation: expected)
        }
    }

    private func cooldownEnded(generation expected: UInt64) {
        guard expected == generation else { return }
        cooldown = nil
        if trailingPending {
            trailingPending = false
            runNowAndStartCooldown()
        } else {
            inCooldown = false
        }
    }
}
