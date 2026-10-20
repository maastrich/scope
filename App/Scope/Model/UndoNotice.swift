import Foundation
import ScopeCore
import ScopeTasks

/// An action the user (or an agent) just took that can still be taken back: a thread closed, a task archived. The
/// ledger (`AppModel.undoLedger`) keeps it for `AppModel.undoWindow`; `UndoNotice` is the toast that offers it for
/// the first seconds.
enum UndoableAction {
    case closedThread(ClosedThread)
    case archivedTask(id: TaskID, name: String, scope: ScopeID)

    /// What the ledger keys the action by, so a second close of the same thread replaces the first.
    var id: String {
        switch self {
        case .closedThread(let closed): "thread:\(closed.id.rawValue)"
        case .archivedTask(let id, _, _): "task:\(id.rawValue)"
        }
    }

    var isClosedThread: Bool {
        if case .closedThread = self { true } else { false }
    }
}

/// Who asked for the close or the archive; the toast says so when it was not the user.
enum CloseRequester: Sendable, Equatable {
    case user
    /// An agent over the control socket, by its name when it gave one.
    case agent(String?)
    /// Scope itself, for the reason the toast gives (`archiveIfMerged`): never the user's keystroke either.
    case automatic(String)

    var isAgent: Bool { self != .user }
}

/// "“Title” closed — Reopen", for `lifetime` after the action, hover holds the countdown. Dismissing the toast
/// does not drop the action: ⌘Z and the palette keep it for the whole `AppModel.undoWindow`.
@MainActor
@Observable
final class UndoNotice: Identifiable {
    let action: UndoableAction
    let requester: CloseRequester
    @ObservationIgnored var onExpire: (@MainActor (UndoNotice) -> Void)?

    static let lifetime: Duration = .seconds(10)

    @ObservationIgnored private var remaining: Duration = UndoNotice.lifetime
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(action: UndoableAction, requester: CloseRequester) {
        self.action = action
        self.requester = requester
    }

    nonisolated var id: String { action.id }

    /// The sentence: what happened, and who did it when it was an agent.
    var text: String {
        let by: String = switch requester {
        case .user: ""
        case .agent(let name): " by \(name ?? "an agent")"
        case .automatic(let reason): ": \(reason)"
        }
        return switch action {
        case .closedThread(let closed): "“\(closed.record.title)” closed\(by)"
        case .archivedTask(_, let name, _): "“\(name)” archived\(by)"
        }
    }

    var buttonTitle: String {
        switch action {
        case .closedThread: "Reopen"
        case .archivedTask: "Undo"
        }
    }

    var usageElement: String {
        switch action {
        case .closedThread: "reopen-thread"
        case .archivedTask: "restore-task"
        }
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
