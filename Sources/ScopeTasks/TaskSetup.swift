import Foundation

/// Where a task's setup command is (spec §4.3): run once in each new sandbox, before the first thread starts.
public enum SetupState: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// No setup was asked for yet, or the record predates setup.
    case notRun
    case running
    case succeeded
    case failed
    /// There was nothing to run, or the user unticked "Run setup".
    case skipped

    /// A setup cut short by a quit cannot be picked up again: its process is gone, so the next launch reports it
    /// as failed rather than leaving a spinner that never stops. Every other state is kept.
    public var normalizedAfterRestart: SetupState {
        self == .running ? .failed : self
    }
}
