import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers

/// Restart Session (`ThreadRestart`): a Claude Code thread's process is hung up and a new one resumes the same
/// conversation. The kill is `ThreadSession.stop`, the start is `launch(_:mode: .resume)` — what a Relaunch does —
/// with the exit in between kept from looking like one: no toast, no auto-close, no resident hold.
extension AppModel {
    /// Who asked, for the journal's `source`.
    enum RestartSource: String {
        case user
        case agent
        /// The agent restarted its own thread: answered first, restarted once its turn is over.
        case ownThread = "self"
    }

    enum RestartOutcome: Equatable {
        case restarted
        case failed(String)

        var failure: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    /// Why the menu item is disabled, `nil` when it is not.
    func restartUnavailable(_ session: ThreadSession) -> String? {
        if restartingThreads.contains(session.id) { return "restarting…" }
        return ThreadRestart.unavailable(profile: session.profile, resumeID: session.record.resumeID)?.reason
    }

    /// From the menu or the palette: asks first when a turn would be cut short, then restarts.
    func restartSessionAsked(_ id: ThreadID) async {
        guard let session = session(id) else { return }
        if session.isAlive, ThreadRestart.interruptsTurn(inTurn: session.activity.inTurn, working: session.isWorking) {
            let confirmed = await confirmDestructive(title: "Restart the session of “\(session.title)”?", verb: "Restart",
                                                     risks: [.interruptsTurn])
            guard confirmed else {
                journalRestart(session, outcome: "cancelled", cause: "in-turn", source: .user, seconds: nil)
                return
            }
        }
        _ = await restartSession(id, source: .user)
    }

    /// Hangs the process up — Esc first when a turn is open, SIGHUP to the pid and its group, SIGKILL if it stays —
    /// and starts `claude --resume <id>` in the same session object: same tab, cwd, task, model, injected settings.
    /// The draft in the field is typed back once the new prompt is up; `note`, when given, is submitted after it.
    func restartSession(_ id: ThreadID, source: RestartSource, note: String? = nil) async -> RestartOutcome {
        guard let session = session(id) else { return .failed("no such thread") }
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> Double {
            let (whole, atto) = (clock.now - start).components
            return Double(whole) + Double(atto) / 1e18
        }
        if let unavailable = ThreadRestart.unavailable(profile: session.profile, resumeID: session.record.resumeID) {
            journalRestart(session, outcome: "unavailable", cause: unavailable.token, source: source, seconds: nil)
            return .failed(unavailable.reason)
        }
        guard !restartingThreads.contains(id) else { return .failed("already restarting") }
        if case .launching = session.phase { return .failed("the thread is starting") }
        restartingThreads.insert(id)
        defer { restartingThreads.remove(id) }
        pendingSelfRestarts.removeValue(forKey: id)?.cancel()
        residentRestarts.removeValue(forKey: id)?.cancel()

        var draft: ClaudeDraft.Retype?
        if session.isAlive {
            draft = session.draftForRestart()
            if session.interruptForRestart() { try? await Task.sleep(for: ThreadRestart.interruptGrace) }
            session.stop(escalateAfter: ThreadRestart.killAfter)
            let deadline = clock.now + ThreadRestart.exitTimeout
            while session.isAlive, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !session.isAlive else {
                // Starting now would put two processes on one conversation.
                problems.error("A thread did not stop for Restart Session",
                               detail: "“\(session.title)” is still running; its session was not restarted. Stop it, then Relaunch.",
                               scope: session.record.scopeID, toast: source == .user)
                journalRestart(session, outcome: "failed", cause: "still-running", source: source, seconds: seconds())
                return .failed("the process did not exit")
            }
        }
        // Closed, or its scope removed, while it went down.
        guard self.session(id) === session else {
            journalRestart(session, outcome: "cancelled", cause: "closed", source: source, seconds: seconds())
            return .failed("the thread was closed")
        }
        let resumeID = session.record.resumeID ?? ""
        session.nextLaunchNotice = "session restarted · resuming \(resumeID.prefix(8))"
        await launch(session, mode: ThreadRestart.resumeMode(profile: session.profile, resumeID: session.record.resumeID))
        if case .failed(let reason) = session.phase {
            journalRestart(session, outcome: "failed", cause: "launch", source: source, seconds: seconds())
            return .failed(reason)
        }
        journalRestart(session, outcome: "ok", cause: nil, source: source, seconds: seconds())
        Log.app.notice("thread \(id.rawValue, privacy: .public): session restarted (\(source.rawValue, privacy: .public))")
        if draft != nil || note != nil { typeAfterRestart(id, draft: draft, note: note) }
        return .restarted
    }

    /// An agent asked to restart its own thread: the restart kills the `scope mcp` it asked through, so the answer
    /// goes first and the restart waits for the turn to end — or `selfRestartTimeout`, after which the agent asked
    /// for it anyway.
    func scheduleSelfRestart(_ id: ThreadID) {
        pendingSelfRestarts[id]?.cancel()
        pendingSelfRestarts[id] = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now + ThreadRestart.selfRestartTimeout
            // Time for the answer to reach the agent before anything else happens.
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled, clock.now < deadline {
                guard let self, let session = self.session(id), session.isAlive else { return }
                if !ThreadRestart.interruptsTurn(inTurn: session.activity.inTurn, working: session.isWorking) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self, self.session(id)?.isAlive == true else { return }
            self.pendingSelfRestarts[id] = nil
            _ = await self.restartSession(id, source: .ownThread, note: ThreadRestart.selfRestartNote)
        }
    }

    /// Once the new process shows its prompt (`InterruptedTurn.isPromptReady`: a `SessionStart` since the restart, or
    /// bracketed paste on long enough), the draft goes back into the field and the note is submitted. Dropped if the
    /// user typed first, or if the prompt is not back within `InterruptedTurn.promptTimeout`.
    private func typeAfterRestart(_ id: ThreadID, draft: ClaudeDraft.Retype?, note: String?) {
        let startedAt = Date.now
        Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var pasteSince: ContinuousClock.Instant?
            while clock.now - start < InterruptedTurn.promptTimeout {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let session = self.session(id) else { return }
                // A tab not on screen starts on its first layout, or after `layoutFallbackDelay`.
                if case .launching = session.phase { continue }
                guard session.isAlive else { return }
                if let typed = session.lastUserInputAt, typed >= startedAt { return }
                let pasteOn = session.terminalView.getTerminal().bracketedPasteMode
                if pasteOn, pasteSince == nil { pasteSince = clock.now }
                if !pasteOn { pasteSince = nil }
                let started = session.lastSessionStartedAt.map { $0 >= startedAt } ?? false
                guard InterruptedTurn.isPromptReady(bracketedPaste: pasteOn, pasteOnFor: pasteSince.map { clock.now - $0 } ?? .zero,
                                                    sessionStarted: started) else { continue }
                // The note first: `submit` stashes a draft already in the field and puts it back after.
                if let note { session.submit(note) }
                if let draft {
                    if note != nil { try? await Task.sleep(for: .seconds(1)) }
                    await session.retype(draft)
                    if draft.droppedAttachments > 0 {
                        Log.app.notice("thread \(id.rawValue, privacy: .public): \(draft.droppedAttachments) pasted blocks or images of the draft not restored")
                    }
                }
                return
            }
            Log.app.notice("thread \(id.rawValue, privacy: .public): prompt not back in time after the restart, draft not typed back")
        }
    }

    private func journalRestart(_ session: ThreadSession, outcome: String, cause: String?, source: RestartSource, seconds: Double?) {
        Journal.record(JournalEvent(kind: .threadRestart, outcome: outcome, cause: cause, task: session.record.taskID,
                                    thread: session.id.rawValue, source: source.rawValue, seconds: seconds))
    }
}
