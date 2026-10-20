import AppKit
import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// Taking a close or an archive back. The real safety net behind the sidebar: whatever asked for it — a hover
/// control, ⌘W, a menu, an agent over the socket — the thread's record or the task's archive is kept for
/// `undoWindow`, a toast offers it for ten seconds, and ⌘Z (or ⇧⌘T for a thread, or the palette) brings it back.
/// A thread comes back in its tab and resumes its driver session when the profile knows how (`LaunchMode.relaunch`);
/// a task comes back with its sandboxes and the changes it had (`reopenTask`).
extension AppModel {
    /// How long an action stays undoable. Longer than the toast: an agent's close is noticed late.
    static let undoWindow: Duration = .seconds(300)

    /// Something — anything — can be taken back right now.
    var canUndo: Bool { !undoLedger.isEmpty(at: .now) }

    /// A thread can be reopened (⇧⌘T, the palette's *Undo Close Thread*).
    var canUndoCloseThread: Bool { undoLedger.live(at: .now).contains { $0.entry.isClosedThread } }

    /// The Edit menu's title for what ⌘Z would do.
    var undoTitle: String {
        switch undoLedger.live(at: .now).last?.entry {
        case .closedThread(let closed): "Undo Close “\(closed.record.title)”"
        case .archivedTask(_, let name, _): "Undo Archive “\(name)”"
        case nil: "Undo"
        }
    }

    /// Records an action just taken and shows its toast.
    func remember(_ action: UndoableAction, by requester: CloseRequester) {
        undoLedger.push(id: action.id, entry: action, at: .now)
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: AppModel.undoWindow)
            guard !Task.isCancelled, let self else { return }
            self.undoLedger.expire(at: .now)
        }
        takeUndoNotice(action.id)?.cancel()
        let notice = UndoNotice(action: action, requester: requester)
        notice.onExpire = { [weak self] notice in self?.dismissUndoNotice(notice.id) }
        undoNotices.append(notice)
        notice.start()
    }

    /// ⌘Z: the most recent action still inside its window.
    func undoLast() {
        guard let action = undoLedger.pop(at: .now) else { return }
        perform(action, via: "shortcut")
    }

    /// ⇧⌘T and the palette: the most recently closed thread, whatever was archived since.
    func undoCloseThread() {
        guard let action = undoLedger.pop(at: .now, where: \.isClosedThread) else { return }
        perform(action, via: "shortcut")
    }

    /// The toast's button.
    func undo(noticeID: String) {
        guard let action = undoLedger.take(id: noticeID, at: .now) else {
            dismissUndoNotice(noticeID)
            return
        }
        perform(action, via: "toast")
    }

    /// The toast goes; the action stays undoable from the keyboard.
    func dismissUndoNotice(_ id: String) {
        takeUndoNotice(id)?.cancel()
    }

    /// Hovering a toast holds its countdown.
    func holdUndoNotice(_ id: String, _ held: Bool) {
        guard let notice = undoNotices.first(where: { $0.id == id }) else { return }
        held ? notice.pause() : notice.start()
    }

    /// A thread reopened by other means (Relaunch from the exit toast) or a task restored from its notice is no
    /// longer something to undo.
    func forgetUndo(id: String) {
        undoLedger.remove(id: id)
        takeUndoNotice(id)?.cancel()
    }

    private func takeUndoNotice(_ id: String) -> UndoNotice? {
        guard let index = undoNotices.firstIndex(where: { $0.id == id }) else { return nil }
        return undoNotices.remove(at: index)
    }

    private func perform(_ action: UndoableAction, via: String) {
        takeUndoNotice(action.id)?.cancel()
        let element: String
        switch action {
        case .closedThread(let closed):
            element = "reopen-thread"
            Task { await reopen(closed) }
        case .archivedTask(let id, _, _):
            element = "restore-task"
            Task { await reopenTask(id) }
        }
        // The usage log counts every undo, whichever control asked for it, under one id per kind.
        let source = Usage.currentInput ?? .app
        Usage.record(source == .keyboard ? .shortcut : .click, "undo.\(element)", source: source, context: via)
    }

    /// Reopens a closed thread with the same record (resumed when the driver can). Nothing to do when its scope is
    /// gone or the thread is somehow back already.
    private func reopen(_ closed: ClosedThread) async {
        guard scope(closed.record.scopeID) != nil, session(closed.id) == nil else { return }
        let session = ThreadSession(record: closed.record, profile: closed.profile)
        register(session, activity: closed.activity)
        await env.threadRecords.save(closed.record)
        selection = .thread(closed.id)
        selectedThreadID = closed.id
        await launch(session, mode: .relaunch(profile: session.profile, resumeID: session.record.resumeID))
    }
}
