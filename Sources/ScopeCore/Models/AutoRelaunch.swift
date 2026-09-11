import Foundation

/// Why a thread that was running when the app went down is not started again when it opens.
public enum AutoRelaunchSkip: Sendable, Equatable {
    /// Auto-relaunch is off in Settings.
    case disabled
    /// ⇧ was held while the app opened.
    case skippedOnce
    /// The thread's own opt-out (`ThreadRecord.relaunchesAtStartup`).
    case optedOut
    /// The thread's scope is no longer declared.
    case scopeUndeclared
    /// The scope folder is not there (an unmounted volume, a moved folder).
    case scopeMissing(String)
    /// The thread's task was closed.
    case taskClosed
    /// The thread's task was archived: its sandboxes are gone.
    case taskArchived
    /// The working directory is gone.
    case cwdMissing(String)
    /// The driver profile is not installed. The app would fall back on a shell, which is not what the thread was.
    case driverMissing(String)

    /// The user asked for it (the setting, ⇧, the thread's opt-out): nothing to report.
    public var isChoice: Bool {
        switch self {
        case .disabled, .skippedOnce, .optedOut: true
        default: false
        }
    }

    /// Completes "Not relaunched: …" in a problem row or a banner.
    public var reason: String {
        switch self {
        case .disabled: "auto-relaunch is off in Settings"
        case .skippedOnce: "⇧ was held while Scope opened"
        case .optedOut: "this thread does not relaunch when Scope opens"
        case .scopeUndeclared: "its scope is no longer declared"
        case .scopeMissing(let path): "the scope folder \(path) is missing"
        case .taskClosed: "its task was closed"
        case .taskArchived: "its task was archived, so its sandboxes are gone"
        case .cwdMissing(let path): "its directory \(path) is missing"
        case .driverMissing(let id): "the \(id) driver profile is not installed"
        }
    }
}

/// One persisted thread and what the app knows about it at launch, for `AutoRelaunchPlanner`.
public struct AutoRelaunchCandidate: Sendable {
    /// Where the thread's task stands. Kept here rather than in `ScopeTasks`, which `ScopeCore` does not see.
    public enum TaskStatus: Sendable, Equatable {
        /// A scope-level thread.
        case none
        case active
        case archived
        /// The record names a task that no longer exists.
        case closed
    }

    public var record: ThreadRecord
    /// `false` for an orphan: no declared scope matches the record.
    public var scopeDeclared: Bool
    public var task: TaskStatus
    /// The profile the record names is installed (the app would otherwise substitute a shell).
    public var driverInstalled: Bool

    public init(record: ThreadRecord, scopeDeclared: Bool = true, task: TaskStatus = .none, driverInstalled: Bool = true) {
        self.record = record
        self.scopeDeclared = scopeDeclared
        self.task = task
        self.driverInstalled = driverInstalled
    }
}

/// What to do with the threads that were running when the app went down.
public struct AutoRelaunchPlan: Sendable, Equatable {
    public struct Skipped: Sendable, Equatable {
        public var id: ThreadID
        public var skip: AutoRelaunchSkip
    }

    /// Threads to start, in order.
    public var launches: [ThreadID] = []
    /// Threads that were running and stay stopped, with why.
    public var skipped: [Skipped] = []

    /// The skipped threads worth telling the user about: something is gone, not a choice they made.
    public var blocked: [Skipped] { skipped.filter { !$0.skip.isChoice } }

    /// Every thread that was running, launched or not. Once the plan has run none of the skipped ones is running any
    /// more, so each must lose `processAlive` or it would come back at a later launch.
    public var considered: [ThreadID] { launches + skipped.map(\.id) }

    /// Pause between two starts. Each thread forks a login shell and a driver that reads its own config; ten at once
    /// make the first seconds of the app sluggish and every one of them slower to come up.
    public static let stagger: Duration = .milliseconds(300)
}

/// Decides which threads come back when the app opens, in which order, and why the others do not.
public enum AutoRelaunchPlanner {
    /// Only records with `processAlive` are considered; the others were not running and are left alone.
    ///
    /// Order: `focus` (the thread the window opens on, the one the user sees start), then the other threads of its task
    /// — or of its scope, for a scope-level thread — which are the tabs next to it, then everything else in the order
    /// given (the sidebar order, oldest first).
    ///
    /// - Parameter pathExists: whether a directory exists; injected so the decision stays pure.
    public static func plan(
        _ candidates: [AutoRelaunchCandidate],
        enabled: Bool,
        skippedOnce: Bool,
        focus: ThreadID? = nil,
        pathExists: (String) -> Bool
    ) -> AutoRelaunchPlan {
        var plan = AutoRelaunchPlan()
        var launchable: [ThreadRecord] = []
        for candidate in candidates where candidate.record.processAlive {
            if let skip = skip(candidate, enabled: enabled, skippedOnce: skippedOnce, pathExists: pathExists) {
                plan.skipped.append(.init(id: candidate.record.id, skip: skip))
            } else {
                launchable.append(candidate.record)
            }
        }
        plan.launches = ordered(launchable, focus: focus).map(\.id)
        return plan
    }

    private static func skip(_ candidate: AutoRelaunchCandidate, enabled: Bool, skippedOnce: Bool,
                             pathExists: (String) -> Bool) -> AutoRelaunchSkip? {
        let record = candidate.record
        if !enabled { return .disabled }
        if skippedOnce { return .skippedOnce }
        if !record.relaunchesAtStartup { return .optedOut }
        if !candidate.scopeDeclared { return .scopeUndeclared }
        if !record.scopeRoot.isEmpty, !pathExists(record.scopeRoot) { return .scopeMissing(record.scopeRoot) }
        switch candidate.task {
        case .closed: return .taskClosed
        case .archived: return .taskArchived
        case .none, .active: break
        }
        if !pathExists(record.cwd) { return .cwdMissing(record.cwd) }
        if !candidate.driverInstalled { return .driverMissing(record.driverID) }
        return nil
    }

    private static func ordered(_ records: [ThreadRecord], focus: ThreadID?) -> [ThreadRecord] {
        guard let focus, let focused = records.first(where: { $0.id == focus }) else { return records }
        func isNeighbour(_ record: ThreadRecord) -> Bool {
            if let task = focused.taskID { return record.taskID == task }
            return record.taskID == nil && record.scopeID == focused.scopeID
        }
        let rest = records.filter { $0.id != focus }
        return [focused] + rest.filter(isNeighbour) + rest.filter { !isNeighbour($0) }
    }
}
