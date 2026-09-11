import Foundation

/// Why a thread is `waiting`.
public enum WaitReason: String, Codable, Sendable, CaseIterable, Hashable {
    /// The driver asked the user a question (`input.requested`).
    case input
    /// The driver needs permission for a tool call (`permission.requested`).
    case permission
}

/// The user-visible state of a thread (spec §4.2): `idle` · `running` · `waiting` · `done` · `failed` · `exited`.
///
/// `waiting` carries its reason. `done` and `failed` are *unread* results: the user has not looked at the
/// thread since its turn ended, and looking at it (`acknowledged`) brings it back to `idle`. `exited` is
/// produced only by the PTY exit callback and absorbs every later event; a relaunch starts from `.initial`
/// again. Without an adapter only `running`, `idle` and `exited` are ever known.
public enum ThreadState: Codable, Sendable, Hashable {
    /// Process alive, nothing happening: ready for the next prompt, or no adapter information yet.
    case idle
    /// A turn is in progress.
    case running
    /// The driver needs an answer or a permission.
    case waiting(reason: WaitReason)
    /// The turn (or the driver session) ended and the user has not looked at the result yet.
    case done
    /// The turn ended on an error the driver reported (rate limit, billing, overloaded API).
    case failed
    /// The process is gone.
    case exited

    /// State of a freshly launched thread and of every record restored after an app restart.
    public static let initial: ThreadState = .idle

    /// `true` for every state but `.exited`.
    public var isAlive: Bool { self != .exited }

    /// `true` when the thread needs the user (badge the app, notify).
    public var needsAttention: Bool {
        if case .waiting = self { return true }
        return false
    }

    /// `true` for a turn that ended while the user was not looking (`done`, `failed`): what showing the thread
    /// clears on its own, unlike a question, which only an answer or Mark as Read clears.
    public var isUnreadResult: Bool {
        self == .done || self == .failed
    }

    /// The state once the user has seen the thread (Mark as Read, or showing a finished thread): a `waiting`,
    /// `done` or `failed` thread goes back to `idle` — seen, ready for the next prompt — and every other state is
    /// left as it is. The next event the driver sends moves it on as usual, so a new question brings the attention
    /// straight back.
    public var acknowledged: ThreadState {
        needsAttention || isUnreadResult ? .idle : self
    }

    /// Persistence-neutral name without the reason: `"idle"`, `"running"`, `"waiting"`, `"done"`, `"failed"`,
    /// `"exited"`.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .waiting: "waiting"
        case .done: "done"
        case .failed: "failed"
        case .exited: "exited"
        }
    }

    /// UI label: `"Idle"`, `"Running"`, `"Needs your answer"`, `"Needs permission"`, `"Done"`, `"Failed"`,
    /// `"Exited"`.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waiting(.input): "Needs your answer"
        case .waiting(.permission): "Needs permission"
        case .done: "Done"
        case .failed: "Failed"
        case .exited: "Exited"
        }
    }

    /// The one state that stands for several threads (a task row, a collapsed group): the most urgent of them,
    /// `waiting` > `failed` > `running` > `done` > `idle` > `exited`. `nil` for no thread at all.
    public static func mostUrgent(_ states: some Sequence<ThreadState>) -> ThreadState? {
        states.max { $0.urgency < $1.urgency }
    }

    private var urgency: Int {
        switch self {
        case .exited: 0
        case .idle: 1
        case .done: 2
        case .running: 3
        case .failed: 4
        case .waiting(.input): 5
        case .waiting(.permission): 6
        }
    }

    /// The state persisted records report after an app restart: every alive state becomes `.idle`,
    /// `.exited` stays (the process is gone either way, but an exited record keeps its banner).
    public var normalizedAfterRestart: ThreadState {
        self == .exited ? .exited : .idle
    }

    /// The transition table. Pure; the only way a state changes.
    ///
    /// | event | next |
    /// |---|---|
    /// | `turnStarted` | `running` |
    /// | `turnEnded` | `done` |
    /// | `inputRequested` | `waiting(input)` |
    /// | `permissionRequested` | `waiting(permission)` |
    /// | `turnFailed` | `failed` |
    /// | `threadEnded` | `done` |
    /// | `processExited` | `exited` |
    ///
    /// `exited` absorbs every event.
    public func applying(_ event: ThreadStateEvent) -> ThreadState {
        if self == .exited { return .exited }
        switch event {
        case .turnStarted: return .running
        case .turnEnded: return .done
        case .turnFailed: return .failed
        case .inputRequested: return .waiting(reason: .input)
        case .permissionRequested: return .waiting(reason: .permission)
        case .threadEnded: return .done
        case .processExited: return .exited
        }
    }
}

extension ThreadState: CaseIterable {
    /// Every state, with both `waiting` reasons.
    public static let allCases: [ThreadState] = [
        .idle, .running, .waiting(reason: .input), .waiting(reason: .permission), .done, .failed, .exited,
    ]
}

/// Everything that can move a `ThreadState`. The adapter events (spec §4.7) plus the PTY exit.
public enum ThreadStateEvent: String, Sendable, Hashable, CaseIterable {
    case turnStarted
    case turnEnded
    /// The turn ended on an error instead of an answer (Claude Code's `StopFailure`).
    case turnFailed
    case inputRequested
    case permissionRequested
    case threadEnded
    /// The PTY reported that the process ended. The only source of `.exited`.
    case processExited
}

/// Where a thread's process is in its lifecycle, as seen by `ThreadSession`.
public enum ProcessPhase: Sendable, Equatable {
    /// Restored from disk, or never launched.
    case notStarted
    /// Waiting for the shell environment or the first layout.
    case launching
    case alive(pid: pid_t, since: Date)
    case exited(ExitStatus)
    /// Launch failure message (executable not found, cwd missing, forkpty failed).
    case failed(String)

    /// `true` only for `.alive`.
    public var isAlive: Bool {
        if case .alive = self { return true }
        return false
    }

    /// The pid when alive.
    public var pid: pid_t? {
        if case .alive(let pid, _) = self { return pid }
        return nil
    }
}
