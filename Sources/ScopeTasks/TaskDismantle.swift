import Foundation

/// What `TaskManager.dismantle` is asked to do with a task.
public enum DismantleMode: Codable, Sendable, Equatable, Hashable {
    /// Sandboxes, processes and root go; the branch and the record stay.
    case archive
    /// Everything `archive` removes, then the record; the branches too when `deleteBranch`.
    case close(deleteBranch: Bool)

    public var isClose: Bool { if case .close = self { true } else { false } }
}

/// A dismantle that started and has not finished, written on the record before the first step so a crash, a quit
/// or a failure leaves a trace the next run (the launch GC, a Retry) picks up again.
public struct PendingCleanup: Codable, Sendable, Equatable {
    public var mode: DismantleMode
    public var since: Date
    /// The failure that stopped the last attempt, `nil` while it runs.
    public var error: String?

    public init(mode: DismantleMode, since: Date = TaskRecord.roundedToMilliseconds(.now), error: String? = nil) {
        self.mode = mode
        self.since = since
        self.error = error
    }
}

/// Something a dismantle did not stop for but the user should hear about.
public enum DismantleNotice: Sendable, Equatable {
    /// The teardown command of `repo` failed; the sandbox was removed anyway.
    case teardownFailed(repo: String, summary: String, log: String)
}

/// What a finished dismantle leaves: the archived record (`nil` once closed) and what went wrong on the way.
public struct DismantleOutcome: Sendable, Equatable {
    public var record: TaskRecord?
    public var notices: [DismantleNotice]

    public init(record: TaskRecord?, notices: [DismantleNotice] = []) {
        self.record = record
        self.notices = notices
    }
}
