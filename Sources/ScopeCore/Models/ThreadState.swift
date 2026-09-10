import Foundation

/// Why a thread is `waiting`.
public enum WaitReason: String, Codable, Sendable, CaseIterable, Hashable {
    /// The driver asked the user a question (`input.requested`).
    case input
    /// The driver needs permission for a tool call (`permission.requested`).
    case permission
}

/// The user-visible state of a thread (spec §4.2): `idle` · `running` · `waiting` · `done` · `exited`.
///
/// `waiting` carries its reason. `exited` is produced only by the PTY exit callback and absorbs
/// every later event; a relaunch starts from `.initial` again. Without an adapter only `running`
/// and `exited` are ever known.
public enum ThreadState: Codable, Sendable, Hashable {
    /// Process alive, nothing happening (or no adapter information yet).
    case idle
    /// A turn is in progress.
    case running
    /// The driver needs input or a permission.
    case waiting(reason: WaitReason)
    /// The turn (or the driver session) ended and the result is ready.
    case done
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

    /// The state once the user has marked the thread as read: a `waiting` thread goes back to `idle` — seen,
    /// no longer asking — and every other state is left as it is. The next event the driver sends moves it on
    /// as usual, so a new question brings the attention straight back.
    public var acknowledged: ThreadState {
        needsAttention ? .idle : self
    }

    /// Persistence-neutral name without the reason: `"idle"`, `"running"`, `"waiting"`, `"done"`, `"exited"`.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .waiting: "waiting"
        case .done: "done"
        case .exited: "exited"
        }
    }

    /// UI label: `"Idle"`, `"Running"`, `"Waiting for input"`, `"Waiting for permission"`, `"Done"`, `"Exited"`.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waiting(.input): "Waiting for input"
        case .waiting(.permission): "Waiting for permission"
        case .done: "Done"
        case .exited: "Exited"
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
    /// | `threadEnded` | `done` |
    /// | `processExited` | `exited` |
    ///
    /// `exited` absorbs every event.
    public func applying(_ event: ThreadStateEvent) -> ThreadState {
        if self == .exited { return .exited }
        switch event {
        case .turnStarted: return .running
        case .turnEnded: return .done
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
        .idle, .running, .waiting(reason: .input), .waiting(reason: .permission), .done, .exited,
    ]
}

/// Everything that can move a `ThreadState`. The five adapter events (spec §4.7) plus the PTY exit.
public enum ThreadStateEvent: String, Sendable, Hashable, CaseIterable {
    case turnStarted
    case turnEnded
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
