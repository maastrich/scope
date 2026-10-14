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
    /// Processes of the task still alive after SIGKILL (`name (pid)`).
    case processesSurvived([String])
    /// The uncommitted changes of `repo` were saved under `ref` before its sandbox went.
    case changesSaved(repo: String, ref: String)
    /// The unmerged branch of `repo` was deleted; its last commit is kept under `ref`.
    case branchSaved(repo: String, branch: String, ref: String)
}

/// What a finished dismantle leaves: the archived record (`nil` once closed) and what went wrong on the way.
public struct DismantleOutcome: Sendable, Equatable {
    public var record: TaskRecord?
    public var notices: [DismantleNotice]
    /// Processes the sweep stopped (`name (pid)`): what the threads left running.
    public var stoppedProcesses: [String]

    public init(record: TaskRecord?, notices: [DismantleNotice] = [], stoppedProcesses: [String] = []) {
        self.record = record
        self.notices = notices
        self.stoppedProcesses = stoppedProcesses
    }
}

/// What one pass of `TaskManager.collectGarbage` did — or, for a dry run, would do.
public struct GarbageReport: Sendable, Equatable {
    /// Sandbox folders no task owns, moved to the trash.
    public var removedFolders: [String] = []
    /// Processes of tasks that are gone (`name (pid)`).
    public var stoppedProcesses: [String] = []
    /// Processes that would not die.
    public var survivors: [String] = []
    /// Base checkouts whose stale worktree records were pruned, with how many.
    public var prunedWorktrees: [String] = []
    /// Salvage refs past their retention.
    public var deletedRefs: [String] = []
    /// Uncommitted work found in a removed folder and saved first (`worktree: ref`).
    public var savedChanges: [String] = []
    /// Items deleted from the trash.
    public var emptiedTrash = 0
    /// Tasks whose archive or close never finished; the app resumes them (it hangs up their threads).
    public var pendingTasks: [TaskID] = []

    public init() {}

    /// Nothing was found to clean.
    public var isEmpty: Bool {
        removedFolders.isEmpty && stoppedProcesses.isEmpty && survivors.isEmpty && prunedWorktrees.isEmpty
            && deletedRefs.isEmpty && emptiedTrash == 0
    }
}
