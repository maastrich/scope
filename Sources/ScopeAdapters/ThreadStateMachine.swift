import Foundation
import ScopeCore

/// Maps adapter events onto the thread state table.
///
/// The table itself lives in `ThreadState.applying(_:)` (ScopeCore) so the PTY exit and the hook events share
/// one source of truth; this type only translates a wire `HookEvent.Kind` into a `ThreadStateEvent`.
///
/// | current       | turn.started | turn.ended | input.requested  | permission.requested  | thread.ended |
/// |---------------|--------------|------------|------------------|-----------------------|--------------|
/// | idle          | running      | done       | waiting(input)   | waiting(permission)   | done         |
/// | running       | running      | done       | waiting(input)   | waiting(permission)   | done         |
/// | waiting(any)  | running      | done       | waiting(input)   | waiting(permission)   | done         |
/// | done          | running      | done       | waiting(input)   | waiting(permission)   | done         |
/// | exited        | exited       | exited     | exited           | exited                | exited       |
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
    public static func next(_ current: ThreadState, on event: AdapterEvent) -> ThreadState {
        if event.kind == .inputRequested, event.reason == "permission" {
            return next(current, on: .permissionRequested)
        }
        return next(current, on: event.kind)
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
        case .inputRequested: .inputRequested
        case .permissionRequested: .permissionRequested
        case .threadEnded: .threadEnded
        case .sessionStarted: nil
        }
    }
}
