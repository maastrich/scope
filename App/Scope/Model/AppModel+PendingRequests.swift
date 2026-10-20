import Foundation
import ScopeAdapters
import ScopeCore

/// Answering what a Claude Code thread asks from Scope (`ClaudePendingRequests`): Allow / Deny a permission, pick a
/// question's options. The answer is typed as the keys a person would press (`ClaudeDialogAnswer`), and only after the
/// terminal was read and found to show that very dialog: a request answered at the terminal meanwhile, or another
/// dialog in its place, types nothing.
extension AppModel {
    /// Pause between two keys: Claude Code reads one per read, and two in one write arrive as a paste.
    static let dialogKeyGap: Duration = .milliseconds(180)

    /// The request on screen in `thread`, when there is one and its thread waits on it.
    func pendingRequest(of thread: ThreadID) -> ClaudePendingRequest? {
        guard let session = session(thread), session.isAlive, session.displayState.needsAttention else { return nil }
        return session.claude.pending.current
    }

    /// Types `answer` to request `requestID` of `thread`; the refusal says why nothing was typed.
    @discardableResult
    func answerPendingRequest(_ thread: ThreadID, requestID: String,
                              with answer: ClaudeDialogAnswer) -> Result<Void, ClaudeDialogAnswer.Refusal> {
        guard let session = session(thread), session.isAlive, session.displayState.needsAttention,
              let request = session.claude.pending.current, request.id == requestID
        else { return .failure(.notOnScreen) }
        let keys: [String]
        switch answer.keys(for: request) {
        case .success(let typed): keys = typed
        case .failure(let refusal): return .failure(refusal)
        }
        let screen = TerminalBridge.transcript(of: session).lines.suffix(80)
        if let refusal = ClaudeDialogAnswer.check(request, screen: Array(screen)) {
            Log.threads.notice("answer to \(requestID, privacy: .public) in \(thread.rawValue, privacy: .public) refused: \(refusal.description, privacy: .public)")
            return .failure(refusal)
        }
        Task { @MainActor [weak session] in
            for (index, key) in keys.enumerated() {
                guard let session, session.isAlive else { return }
                if index > 0 { try? await Task.sleep(for: Self.dialogKeyGap) }
                session.send(key)
            }
            // A question's own tool report follows its last key; a permission's may come minutes later.
            session?.answered(requestID)
        }
        clearNotifications(for: thread)
        return .success(())
    }

    /// Allow / Deny on a permission's notification. A refusal replaces the banner, the one place the user is looking.
    func answerPermissionFromNotification(_ thread: ThreadID, requestID: String?, allow: Bool) {
        guard let requestID else { return }
        if case .failure(let refusal) = answerPendingRequest(thread, requestID: requestID, with: allow ? .allow : .deny) {
            notifier.post(ThreadNotificationContent(title: allow ? "Not allowed" : "Not denied", body: refusal.description),
                          threadID: thread)
        }
    }
}
