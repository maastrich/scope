import Foundation

/// The two threads Scope keeps in every declared scope, at its root, for as long as the scope is declared: an agent
/// to drive the scope from (open tasks, talk to the other threads) and a shell to try something by hand without
/// setting up a task.
///
/// They are ordinary threads — a record, a driver, a PTY — with three differences: Scope creates them, nobody can
/// close them (only stop them), and a process that dies on its own is started again (`ResidentRestart`).
public enum ResidentRole: String, Codable, Sendable, CaseIterable, Hashable {
    case orchestrator
    case terminal

    /// The label a new record gets; the user may rename it.
    public var title: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .terminal: "Terminal"
        }
    }

    /// The driver profile the terminal always runs. The orchestrator's comes from the preferences.
    public static let terminalDriverID = "shell"
}

/// What the persisted records lack, or have too much of, for every declared scope to hold exactly one thread of each
/// role.
public struct ResidentReconciliation: Sendable, Equatable {
    public struct Missing: Sendable, Equatable, Hashable {
        public var scopeID: ScopeID
        public var role: ResidentRole

        public init(scopeID: ScopeID, role: ResidentRole) {
            self.scopeID = scopeID
            self.role = role
        }
    }

    /// Records to create, scope by scope in the order given, the orchestrator first.
    public var missing: [Missing] = []
    /// Records that claim a role another record of the same scope already holds. They become ordinary threads rather
    /// than being deleted: whatever runs in them is the user's.
    public var demoted: [ThreadID] = []

    /// Matches the records to the scopes. A record holds its role when it is the first of its scope to claim it, in the
    /// order given (the restore order, oldest first). Two can claim one when a scope was removed while its threads
    /// were kept as orphans, then declared again and rebound.
    public static func reconcile(_ records: [ThreadRecord], scopes: [ScopeID]) -> ResidentReconciliation {
        var result = ResidentReconciliation()
        var held: Set<Missing> = []
        for record in records {
            guard let role = record.resident else { continue }
            let slot = Missing(scopeID: record.scopeID, role: role)
            if held.contains(slot) {
                result.demoted.append(record.id)
            } else {
                held.insert(slot)
            }
        }
        for scope in scopes {
            for role in ResidentRole.allCases where !held.contains(Missing(scopeID: scope, role: role)) {
                result.missing.append(Missing(scopeID: scope, role: role))
            }
        }
        return result
    }
}

/// Why a resident thread is stopped and Scope is not starting it again. Lives in memory: a new app launch clears it,
/// and so does any start the user asks for (Relaunch, Start Fresh).
public enum ResidentHold: Sendable, Equatable {
    /// Stop (⌘.), or an agent's `thread stop`: the user wants it stopped, so it stays stopped until Relaunch.
    case stopped
    /// The command could not be executed (exit 127): restarting would fail the same way.
    case cannotStart
    /// It died too soon after starting this many times in a row.
    case keepsExiting(Int)

    /// Completes "Not restarted: …".
    public var reason: String {
        switch self {
        case .stopped: "it was stopped"
        case .cannotStart: "its command could not be started"
        case .keepsExiting(let count): "it exited \(count) times in a row within seconds of starting"
        }
    }
}

/// What to do when a resident thread's process exits without anyone asking it to.
public enum ResidentRestart {
    public enum Decision: Sendable, Equatable {
        /// Start it again after `delay`. `fresh` starts a new driver session instead of resuming the last one.
        case restart(after: Duration, fresh: Bool)
        /// Leave it stopped, and say why.
        case hold(ResidentHold)
    }

    /// A run shorter than this counts as a quick exit: the driver is broken, not finished.
    public static let quickRun: Duration = .seconds(10)
    /// Quick exits in a row before giving up. Three is enough to tell a broken driver from bad luck, and few enough
    /// that a crash loop costs seconds, not a busy CPU.
    public static let maxQuickExits = 3
    /// The longest pause between two restarts.
    public static let maxDelay: Duration = .seconds(30)

    /// - Parameters:
    ///   - status: how the process ended.
    ///   - ranFor: how long it ran; `nil` when the start time is unknown, which counts as a quick exit.
    ///   - quickExits: quick exits in a row before this one.
    /// - Returns: the decision, and the quick-exit count to remember for the next exit.
    public static func decide(_ status: ExitStatus, ranFor: Duration?, quickExits: Int) -> (Decision, quickExits: Int) {
        if status.isExecFailure { return (.hold(.cannotStart), quickExits) }
        let quick = ranFor.map { $0 < quickRun } ?? true
        let count = quick ? quickExits + 1 : 0
        if count >= maxQuickExits { return (.hold(.keepsExiting(count)), count) }
        // 1 s after a run that lasted, then 2 s, 4 s, …: long enough not to spin, short enough to look instant.
        let delay = min(Duration.seconds(1 << count), maxDelay)
        // A clean exit is someone ending the session (`exit`, `/exit`, ^D): they get a new one, not the one they left.
        // After a quick exit the last session may be what fails to come back (a resume id the driver lost), so the
        // next try does not resume either.
        let fresh = status.isClean || count > 0
        return (.restart(after: delay, fresh: fresh), count)
    }
}
