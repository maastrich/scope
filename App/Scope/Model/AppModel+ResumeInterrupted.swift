import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore

/// Asking a relaunched agent to go on with the turn the restart cut short (spec §4.2, `InterruptedTurn`). The
/// decision is `InterruptedTurn`'s; this waits for the driver's prompt and types the message.
extension AppModel {
    /// Called by the auto-relaunch right after `session` was started. Consumes the record's stamp whatever happens,
    /// so one interruption asks once; then, when the thread qualifies, waits for its prompt the way a message to a
    /// thread being started does (`UserMessage.canTypeIntoStartedThread`) and submits the message. Dropped when the
    /// prompt is not up within `InterruptedTurn.promptTimeout`, or when the user types into it first.
    func resumeInterruptedTurn(of session: ThreadSession, resumed: Bool, skippedOnce: Bool) {
        guard let interruptedAt = session.record.interruptedTurn else { return }
        let skip = InterruptedTurn.skip(session.record, enabled: config.preferences.resumeInterruptedTurns,
                                        skippedOnce: skippedOnce, reportsTurns: session.deliversEvents,
                                        relaunched: session.isAlive || isLaunchingThread(session))
        session.consumeInterruptedTurn()
        if let skip {
            Log.app.info("thread \(session.id.rawValue, privacy: .public): interrupted turn not resumed (\(String(describing: skip), privacy: .public))")
            return
        }
        let id = session.id
        let text = InterruptedTurn.message(interruptedAt: interruptedAt, now: .now, resumed: resumed)
        session.setResumingAfterRestart(true)
        Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            let startedAt = Date.now
            var pasteSince: ContinuousClock.Instant?
            defer { self?.session(id)?.setResumingAfterRestart(false) }
            while clock.now - start < InterruptedTurn.promptTimeout {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let session = self.session(id) else { return }
                if case .failed = session.phase { return }
                if case .exited = session.phase { return }
                // The user got there first — in the terminal, or through a message that already opened a turn.
                if let typed = session.lastUserInputAt, typed >= startedAt { return }
                if let prompted = session.lastPromptAt, prompted >= startedAt { return }
                if session.isWorking { return }
                // The user path types blind once `UserMessage.startupTimeout` is over rather than lose the user's
                // words; this message is Scope's own, so it waits for the prompt and is dropped otherwise — typed
                // into a driver still starting, it would be lost anyway.
                let pasteOn = session.isAlive && session.terminalView.getTerminal().bracketedPasteMode
                if pasteOn, pasteSince == nil { pasteSince = clock.now }
                if !pasteOn { pasteSince = nil }
                let started = session.lastSessionStartedAt.map { $0 >= startedAt } ?? false
                if InterruptedTurn.isPromptReady(bracketedPaste: pasteOn, pasteOnFor: pasteSince.map { clock.now - $0 } ?? .zero,
                                                 sessionStarted: started) {
                    session.submit(text)
                    Log.app.info("thread \(id.rawValue, privacy: .public): asked to go on after the restart")
                    return
                }
            }
            Log.app.notice("thread \(id.rawValue, privacy: .public): prompt not back in time, not asked to go on")
        }
    }

    private func isLaunchingThread(_ session: ThreadSession) -> Bool {
        if case .launching = session.phase { return true }
        return false
    }
}
