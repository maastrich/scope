import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers

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

    // MARK: Waiting, at once

    /// A permission was described and nobody decided it within `ClaudeAgentsReport.settle` (another hook, auto mode):
    /// asks Claude Code whether the session now waits on its dialog, and if so shows it waiting — with what it asks —
    /// without the six seconds `permission_prompt` takes.
    ///
    /// The dialog is up while another `PermissionRequest` hook (a companion app) still decides, so a session that waits
    /// at one second may be answered at three. Until `permission_prompt` takes over, the session is asked again each
    /// second (`ClaudeAgentsReport.followUps` times at most): one that no longer waits had it decided elsewhere, and the
    /// thread goes back to work instead of waiting for the tool to end. A handful of `claude agents --json` per
    /// permission left undecided, never more.
    func confirmPermissionSoon(_ session: ThreadSession) {
        guard session.claude.pending.awaitsConfirmation, let sessionID = session.claude.sessionID else { return }
        let shellResolver = env.shell
        let home = env.home
        Task { [weak self, weak session] in
            try? await Task.sleep(for: ClaudeAgentsReport.settle)
            guard let session, session.isAlive, session.claude.pending.awaitsConfirmation else { return }
            let shell = await shellResolver.environment()
            let runner = SubprocessHeadlessRunner(path: shell.path, shell: shell.shell)
            /// `nil` when Claude Code could not be asked: no evidence either way.
            func waits() async -> Bool? {
                guard let result = try? await runner.run(argv: ClaudeAgentsReport.argv, cwd: home, timeout: .seconds(5)),
                      result.exitCode == 0 else { return nil }
                return ClaudeAgentsReport(json: result.stdout).waitsOnPermission(sessionID: sessionID)
            }
            guard await waits() == true, session.isAlive, session.claude.pending.awaitsConfirmation,
                  let confirmed = session.confirmPermission()
            else { return }
            session.confirmedEarly = confirmed
            // As if `permission_prompt` had come: the state, the activity, the notification.
            self?.handle(AdapterEvent(threadID: session.id, kind: .permissionRequested,
                                      payload: [HookEvent.viaKey: Self.viaAgents]))
            for _ in 0..<ClaudeAgentsReport.followUps {
                try? await Task.sleep(for: ClaudeAgentsReport.settle)
                guard session.isAlive, session.confirmedEarly == confirmed,
                      session.claude.pending.current?.id == confirmed else { return }
                if await waits() == false {
                    guard session.confirmedEarly == confirmed else { return }
                    session.decidedElsewhere(confirmed)
                    self?.clearNotifications(for: session.id)
                    return
                }
            }
        }
    }

    /// `HookEvent.viaKey` of the event `confirmPermissionSoon` stands in for `permission_prompt` with.
    static let viaAgents = "claude-agents"
}
