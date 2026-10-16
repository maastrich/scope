import Foundation

/// A turn the app took down with it, and how the thread picks its work back up when the app opens again
/// (spec §4.2).
///
/// Auto-relaunch brings a thread's process back, but a resumed driver sits at its prompt: nothing tells it to go
/// on, and the sidebar says "stopped mid-turn" until someone types. So a thread whose driver said it was running
/// when the app went down is stamped (`ThreadRecord.interruptedTurn`) — at quit with the exact time, at the next
/// load when the record still says a process was alive and mid-turn (a crash, a reboot) — and, once relaunched
/// and at its prompt, is handed `message` as if the user had typed it. The stamp is consumed when the thread is
/// considered, whatever the outcome, so one interruption asks once.
public enum InterruptedTurn {
    /// Why a stamped thread is not asked to go on.
    public enum Skip: Sendable, Equatable {
        /// The thread had no turn in progress when the app went down.
        case notInterrupted
        /// Settings › Threads › Ask agents to continue after a restart is off.
        case disabled
        /// ⇧ was held while the app opened: nothing starts, nothing is asked.
        case skippedOnce
        /// The thread was not started again (auto-relaunch skipped or blocked it).
        case notRelaunched
        /// A shell, or a driver whose adapter never reports a turn: there was no turn to finish.
        case driverSilent
    }

    /// How long a relaunched driver gets to show its prompt before the message is dropped. Longer than the wait
    /// for a message of the user's (8 s): a driver resuming a long session, or installing its update first, takes
    /// its time, and nobody is waiting on this one.
    public static let promptTimeout: Duration = .seconds(30)

    /// How long bracketed paste must have been on before a driver that never says it started is trusted to read a
    /// paste. Claude Code turns the mode on about a second before its prompt takes input; a paste in between is lost.
    public static let pasteSettle: Duration = .seconds(2)

    /// Whether the relaunched driver is at its prompt. Claude Code says so itself (`session.started` from its hooks,
    /// `sessionStarted`); any driver that turned bracketed paste on and kept it on for `pasteSettle` is taken at
    /// its word. Without bracketed paste nothing is typed: the text would be submitted at its first line break.
    public static func isPromptReady(bracketedPaste: Bool, pasteOnFor: Duration, sessionStarted: Bool) -> Bool {
        guard bracketedPaste else { return false }
        return sessionStarted || pasteOnFor >= pasteSettle
    }

    /// What `scope list` shows and the sidebar caption says while the thread is being asked to go on.
    public static let activityLine = "resuming after restart"
    public static let headline = "Resuming after restart…"

    /// Whether a thread going down with the app leaves a turn behind: its driver reported one and nothing closed
    /// it. A thread waiting on a question or a permission is not mid-turn — the agent stopped on purpose.
    public static func isMidTurn(_ state: ThreadState?) -> Bool {
        state == .running
    }

    /// `record` as the app writes it while quitting: stamped at `date` when its thread is mid-turn, unchanged
    /// otherwise. A stamp from an earlier interruption still on the record is replaced: the newer one is the one
    /// the message should name.
    public static func marking(_ record: ThreadRecord, state: ThreadState?, at date: Date) -> ThreadRecord {
        guard isMidTurn(state) else { return record }
        var next = record
        next.interruptedTurn = date
        return next
    }

    /// `record` as read back from disk, before its state is normalised: a process that was alive and mid-turn
    /// with no stamp means the app did not get to write one — it crashed, or the machine went down — so it is
    /// stamped at `now`, the closest the app knows. A record already stamped keeps its stamp.
    public static func noting(_ record: ThreadRecord, now: Date) -> ThreadRecord {
        guard record.interruptedTurn == nil, record.processAlive, isMidTurn(record.lastState) else { return record }
        var next = record
        next.interruptedTurn = now
        return next
    }

    /// Why `record`'s thread is not asked to go on at this launch; `nil` when it is.
    public static func skip(_ record: ThreadRecord, enabled: Bool, skippedOnce: Bool,
                            reportsTurns: Bool, relaunched: Bool) -> Skip? {
        if record.interruptedTurn == nil { return .notInterrupted }
        if skippedOnce { return .skippedOnce }
        if !enabled { return .disabled }
        if !reportsTurns { return .driverSilent }
        if !relaunched { return .notRelaunched }
        return nil
    }

    /// `record` once its interruption was considered: the stamp is gone, so a later launch does not ask again.
    public static func consumed(_ record: ThreadRecord) -> ThreadRecord {
        var next = record
        next.interruptedTurn = nil
        return next
    }

    /// The message typed into the thread, signed as Scope's own so the agent does not take it for the user's.
    ///
    /// `resumed` says whether the driver's session came back (`claude --resume`): then the agent remembers its
    /// plan and is asked to re-read it. A fresh session remembers nothing, so it is sent to the worktree and the
    /// task context instead.
    public static func message(interruptedAt: Date, now: Date, resumed: Bool,
                               locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let when = timeText(interruptedAt, now: now, locale: locale, timeZone: timeZone)
        let header = resumed
            ? "[Scope: Scope restarted while you were working (interrupted at \(when)); your session was resumed]"
            : "[Scope: Scope restarted while you were working (interrupted at \(when)); your previous session could not be resumed, this one starts fresh]"
        let steps = resumed
            ? "check `git status` / `git log`, re-read your last plan, and finish."
            : "check `git status` / `git log`, read the task context, and finish what was started."
        return "\(header)\nContinue from where the worktree stands: \(steps) Reply when done."
    }

    /// `14:32:05` for an interruption earlier the same day, `Oct 15 at 14:32:05` for an older one: a thread that
    /// stayed down over a night should say so.
    public static func timeText(_ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar, timeZone: timeZone))
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone))
        return "\(day) at \(time)"
    }
}
