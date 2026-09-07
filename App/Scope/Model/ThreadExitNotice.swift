import Foundation
import ScopeCore
import ScopeDrivers

/// A thread whose process exited while the app was running: its tab is already gone, the record is
/// still on disk. Shown as a toast for `lifetime`, then closed for good unless relaunched. The
/// countdown pauses while the toast is hovered.
@MainActor
@Observable
final class ThreadExitNotice: Identifiable {
    nonisolated let record: ThreadRecord
    let profile: DriverProfile
    let status: ExitStatus
    /// OSC title at the time of the exit, when the process set one.
    let lastTitle: String?
    /// Fires once when the countdown ends; never after `cancel()`.
    @ObservationIgnored var onExpire: (@MainActor (ThreadExitNotice) -> Void)?

    static let lifetime: Duration = .seconds(10)

    @ObservationIgnored private var remaining: Duration = ThreadExitNotice.lifetime
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(record: ThreadRecord, profile: DriverProfile, status: ExitStatus, lastTitle: String?) {
        self.record = record
        self.profile = profile
        self.status = status
        self.lastTitle = lastTitle
    }

    nonisolated var id: ThreadID { record.id }
    var title: String { record.title }

    /// `"exit 1"` → `"status 1"`, `"killed by SIGKILL (9)"` → `"SIGKILL"`, unknown → `"unknown status"`.
    var shortStatus: String {
        if let code = status.code { return "status \(code)" }
        if let signal = status.signal { return ExitStatus.signalName(signal) }
        return "unknown status"
    }

    /// How long the last process ran, when its start is known.
    var duration: Duration? {
        guard let launchedAt = record.lastLaunchedAt else { return nil }
        return .seconds(status.at.timeIntervalSince(launchedAt))
    }

    // MARK: Countdown

    func start() {
        guard timer == nil else { return }
        let wait = remaining
        startedAt = .now
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.onExpire?(self)
        }
    }

    func pause() {
        guard let timer, let startedAt else { return }
        timer.cancel()
        self.timer = nil
        remaining = max(.zero, remaining - startedAt.duration(to: .now))
        self.startedAt = nil
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        startedAt = nil
        onExpire = nil
    }
}
