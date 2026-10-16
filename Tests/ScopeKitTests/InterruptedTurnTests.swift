import Foundation
import Testing
@testable import ScopeCore

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")

private func record(alive: Bool = true, state: ThreadState? = .running, stamped: Date? = nil) throws -> ThreadRecord {
    var record = ThreadRecord(
        id: try #require(ThreadID(rawValue: "aaaaaaaaaaa1")),
        scopeID: acme, scopeRoot: "/scopes/acme", driverID: "claude-code", title: "acme",
        cwd: "/scopes/acme", cwdKind: .scopeRoot
    )
    record.processAlive = alive
    record.lastState = state
    record.interruptedTurn = stamped
    return record
}

private let quitAt = Date(timeIntervalSince1970: 1_760_021_600) // 2025-10-09 14:53:20 UTC
private let utc = TimeZone(identifier: "UTC")!
private let posix = Locale(identifier: "en_GB")

@Suite struct InterruptedTurnTests {
    // MARK: Detection

    @Test func onlyARunningTurnIsMidTurn() {
        #expect(InterruptedTurn.isMidTurn(.running))
        for state in [ThreadState.idle, .waiting(reason: .input), .waiting(reason: .permission), .done, .failed, .exited] {
            #expect(!InterruptedTurn.isMidTurn(state), "\(state)")
        }
        #expect(!InterruptedTurn.isMidTurn(nil))
    }

    @Test func quittingStampsAThreadMidTurnAndLeavesTheOthersAlone() throws {
        let working = InterruptedTurn.marking(try record(), state: .running, at: quitAt)
        #expect(working.interruptedTurn == quitAt)
        let waiting = InterruptedTurn.marking(try record(), state: .waiting(reason: .input), at: quitAt)
        #expect(waiting.interruptedTurn == nil)
        // A shell reports nothing, so its state is unknown.
        let shell = InterruptedTurn.marking(try record(), state: nil, at: quitAt)
        #expect(shell.interruptedTurn == nil)
    }

    @Test func quittingReplacesAnOlderStamp() throws {
        let older = quitAt.addingTimeInterval(-3600)
        let marked = InterruptedTurn.marking(try record(stamped: older), state: .running, at: quitAt)
        #expect(marked.interruptedTurn == quitAt)
    }

    @Test func aRecordLoadedAliveAndMidTurnWithoutAStampWasACrash() throws {
        let launch = quitAt.addingTimeInterval(120)
        #expect(InterruptedTurn.noting(try record(), now: launch).interruptedTurn == launch)
        // Written by a quit: the quit's stamp is the one that counts.
        #expect(InterruptedTurn.noting(try record(stamped: quitAt), now: launch).interruptedTurn == quitAt)
        // Not running when the app went down: nothing to go on with.
        #expect(InterruptedTurn.noting(try record(state: .idle), now: launch).interruptedTurn == nil)
        #expect(InterruptedTurn.noting(try record(state: .waiting(reason: .permission)), now: launch).interruptedTurn == nil)
        // A stopped thread is not relaunched, so it is not asked either.
        #expect(InterruptedTurn.noting(try record(alive: false, state: .running), now: launch).interruptedTurn == nil)
    }

    // MARK: Which threads

    @Test func aStampedRelaunchedAgentQualifies() throws {
        let skip = InterruptedTurn.skip(try record(stamped: quitAt), enabled: true, skippedOnce: false,
                                        reportsTurns: true, relaunched: true)
        #expect(skip == nil)
    }

    @Test func eachReasonNotToAsk() throws {
        let stamped = try record(stamped: quitAt)
        #expect(InterruptedTurn.skip(try record(), enabled: true, skippedOnce: false, reportsTurns: true, relaunched: true)
            == .notInterrupted)
        #expect(InterruptedTurn.skip(stamped, enabled: false, skippedOnce: false, reportsTurns: true, relaunched: true)
            == .disabled)
        #expect(InterruptedTurn.skip(stamped, enabled: true, skippedOnce: true, reportsTurns: true, relaunched: true)
            == .skippedOnce)
        #expect(InterruptedTurn.skip(stamped, enabled: true, skippedOnce: false, reportsTurns: false, relaunched: true)
            == .driverSilent)
        #expect(InterruptedTurn.skip(stamped, enabled: true, skippedOnce: false, reportsTurns: true, relaunched: false)
            == .notRelaunched)
    }

    @Test func shiftWinsOverTheSettingAndTheSettingOverTheDriver() throws {
        let stamped = try record(stamped: quitAt)
        #expect(InterruptedTurn.skip(stamped, enabled: false, skippedOnce: true, reportsTurns: false, relaunched: false)
            == .skippedOnce)
        #expect(InterruptedTurn.skip(stamped, enabled: false, skippedOnce: false, reportsTurns: false, relaunched: false)
            == .disabled)
    }

    // MARK: Once per interruption

    @Test func consumingTheStampMeansNoSecondAsk() throws {
        let stamped = try record(stamped: quitAt)
        let consumed = InterruptedTurn.consumed(stamped)
        #expect(consumed.interruptedTurn == nil)
        #expect(InterruptedTurn.skip(consumed, enabled: true, skippedOnce: false, reportsTurns: true, relaunched: true)
            == .notInterrupted)
        // Loaded again at a later launch, idle this time: still nothing.
        var later = consumed
        later.lastState = .idle
        #expect(InterruptedTurn.noting(later, now: quitAt.addingTimeInterval(600)).interruptedTurn == nil)
    }

    @Test func theStampSurvivesARoundTripAndItsAbsenceDecodes() throws {
        let stamped = try record(stamped: quitAt)
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(stamped)
        let back = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: data)
        #expect(back.interruptedTurn == quitAt)
        let bare = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: try JSONStore.makeEncoder(fractionalSeconds: true).encode(try record()))
        #expect(bare.interruptedTurn == nil)
    }

    // MARK: The prompt

    @Test func thePromptIsUpWhenTheDriverSaysSoOrPasteModeHasSettled() {
        #expect(!InterruptedTurn.isPromptReady(bracketedPaste: false, pasteOnFor: .seconds(60), sessionStarted: true))
        #expect(InterruptedTurn.isPromptReady(bracketedPaste: true, pasteOnFor: .zero, sessionStarted: true))
        #expect(!InterruptedTurn.isPromptReady(bracketedPaste: true, pasteOnFor: .seconds(1), sessionStarted: false))
        #expect(InterruptedTurn.isPromptReady(bracketedPaste: true, pasteOnFor: InterruptedTurn.pasteSettle, sessionStarted: false))
    }

    // MARK: The message

    @Test func theMessageIsSignedByScopeAndNamesTheTime() {
        let text = InterruptedTurn.message(interruptedAt: quitAt, now: quitAt.addingTimeInterval(480), resumed: true,
                                           locale: posix, timeZone: utc)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("[Scope: "))
        #expect(lines[0].hasSuffix("]"))
        #expect(lines[0].contains("interrupted at 14:53:20"))
        #expect(lines[0].contains("resumed"))
        #expect(lines[1].contains("`git status` / `git log`"))
        #expect(lines[1].contains("re-read your last plan"))
        #expect(lines[1].hasSuffix("Reply when done."))
    }

    @Test func aFreshSessionIsSentToTheTaskContextInsteadOfItsPlan() {
        let text = InterruptedTurn.message(interruptedAt: quitAt, now: quitAt.addingTimeInterval(480), resumed: false,
                                           locale: posix, timeZone: utc)
        #expect(text.contains("could not be resumed"))
        #expect(text.contains("read the task context"))
        #expect(!text.contains("re-read your last plan"))
        #expect(text.hasSuffix("Reply when done."))
    }

    @Test func anInterruptionFromAnotherDayNamesTheDay() {
        let sameDay = InterruptedTurn.timeText(quitAt, now: quitAt.addingTimeInterval(3600), locale: posix, timeZone: utc)
        #expect(sameDay == "14:53:20")
        let nextDay = InterruptedTurn.timeText(quitAt, now: quitAt.addingTimeInterval(86_400), locale: posix, timeZone: utc)
        #expect(nextDay == "9 Oct 2025 at 14:53:20")
    }
}
