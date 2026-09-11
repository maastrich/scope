import Foundation
import ScopeCore

/// Maps adapter events onto the thread state table.
///
/// The table itself lives in `ThreadState.applying(_:)` (ScopeCore) so the PTY exit and the hook events share
/// one source of truth; this type only translates a wire `HookEvent.Kind` into a `ThreadStateEvent`.
///
/// | current       | turn.started | turn.ended | turn.failed | input.requested  | permission.requested  | thread.ended |
/// |---------------|--------------|------------|-------------|------------------|-----------------------|--------------|
/// | alive (any)   | running      | done       | failed      | waiting(input)   | waiting(permission)   | done         |
/// | exited        | exited       | exited     | exited      | exited           | exited                | exited       |
///
/// `session.started` (not in the table) leaves every state unchanged: it only carries the session id.
///
/// `exited` is produced only by the PTY `processTerminated` callback (`ThreadStateEvent.processExited`), never
/// by an adapter event: `thread.ended` is `done` (the driver finished its work; the process may still be
/// alive). `exited` absorbs everything; a relaunch resets the state to `ThreadState.initial` externally.
public enum ThreadStateMachine {
    /// Next state after `kind` arrives while in `current`.
    public static func next(_ current: ThreadState, on kind: HookEvent.Kind) -> ThreadState {
        guard let stateEvent = kind.stateEvent else { return current }
        return current.applying(stateEvent)
    }

    /// Same table, refined by the event payload: `input.requested` with `reason=permission` counts as a
    /// permission request (some drivers only have one notification hook and say why in the payload).
    ///
    /// A permission request derived from Claude Code's `Notification` hook never replaces a question: the question
    /// UI (`AskUserQuestion`) sends a `permission_prompt` notification a few seconds in, which carries no tool name
    /// to tell it from a real one. The real ones arrive through `PermissionRequest`, which does.
    public static func next(_ current: ThreadState, on event: AdapterEvent) -> ThreadState {
        if event.kind == .inputRequested, event.reason == "permission" {
            return next(current, on: .permissionRequested)
        }
        if event.kind == .permissionRequested, current == .waiting(reason: .input),
           event.payload[HookEvent.viaKey] == HookEvent.viaNotification {
            return current
        }
        return next(current, on: event.kind)
    }

    /// Next state after the user's own input, or `nil` when it changes nothing.
    ///
    /// - `interrupt` while a turn runs or waits: the turn is over (`idle`). Should the driver keep going after
    ///   all, its next tool hook sets `running` again.
    /// - `submit` while a permission is pending: the user answered the prompt and the tool now runs.
    /// - `submit` of a typed prompt, for an adapter that never reports a turn start (Codex `notify`): a turn starts.
    ///   Adapters that do report it are left to their hook — a slash command, for one, starts no turn.
    public static func next(_ current: ThreadState, onUserInput signal: TerminalInputSignal,
                            adapterReportsTurnStart: Bool) -> ThreadState? {
        switch (signal, current) {
        case (.interrupt, .running), (.interrupt, .waiting):
            return .idle
        case (.submit, .waiting(.permission)):
            return .running
        case (.submit(hadText: true), .idle), (.submit(hadText: true), .done), (.submit(hadText: true), .failed):
            return adapterReportsTurnStart ? nil : .running
        default:
            return nil
        }
    }

    /// `true` for the state adapter events cannot leave (`exited`).
    public static func isAbsorbing(_ state: ThreadState) -> Bool {
        state == .exited
    }
}

extension HookEvent.Kind {
    /// The `ThreadStateEvent` this wire event stands for; `nil` for `session.started`, which moves nothing.
    public var stateEvent: ThreadStateEvent? {
        switch self {
        case .turnStarted: .turnStarted
        case .turnEnded: .turnEnded
        case .turnFailed: .turnFailed
        case .inputRequested: .inputRequested
        case .permissionRequested: .permissionRequested
        case .threadEnded: .threadEnded
        case .sessionStarted: nil
        }
    }
}
