import Foundation
import Testing
import ScopeCore
import ScopeDrivers
import ScopeGit
@testable import ScopeTasks

@Suite struct CloseGuardTests {
    // MARK: Threads

    @Test func aThreadInTheMiddleOfATurnIsTheOnlyAgentThreadThatAsks() {
        #expect(CloseGuard.threadRisks(isAlive: true, isWorking: true, reportsActivity: true) == [.interruptsTurn])
        #expect(CloseGuard.threadRisks(isAlive: true, isWorking: false, reportsActivity: true).isEmpty)
        #expect(CloseGuard.threadRisks(isAlive: false, isWorking: false, reportsActivity: true).isEmpty)
    }

    @Test func aLiveShellCountsAsWorkingSinceItCannotSay() {
        #expect(CloseGuard.threadRisks(isAlive: true, isWorking: false, reportsActivity: false) == [.runningProcess])
        #expect(CloseGuard.threadRisks(isAlive: false, isWorking: false, reportsActivity: false).isEmpty)
    }

    // MARK: Tasks

    @Test func aFinishedMergedTaskArchivesWithoutAQuestion() {
        let facts = TaskFacts(threads: [.done, .exited], additions: 40, deletions: 3, isDirty: false,
                              pullRequests: [PullRequestFacts(number: 84, state: .merged)])
        #expect(CloseGuard.taskRisks(facts).isEmpty)
        #expect(!CloseGuard.shouldConfirm(CloseGuard.taskRisks(facts), preference: true))
    }

    @Test func aWorkingAgentUncommittedChangesAndAnOpenPullRequestEachAsk() {
        #expect(CloseGuard.taskRisks(TaskFacts(threads: [.idle, .running])) == [.interruptsTurn])
        #expect(CloseGuard.taskRisks(TaskFacts(isDirty: true)) == [.uncommittedChanges])
        #expect(CloseGuard.taskRisks(TaskFacts(pullRequests: [PullRequestFacts(number: 12, state: .open)]))
                == [.openPullRequest(number: 12)])
        let all = TaskFacts(threads: [.running], isDirty: true,
                            pullRequests: [PullRequestFacts(number: 7, state: .closed), PullRequestFacts(number: 9, state: .open)])
        #expect(CloseGuard.taskRisks(all) == [.interruptsTurn, .uncommittedChanges, .openPullRequest(number: 9)])
        #expect(CloseGuard.describe(CloseGuard.taskRisks(all)).count == 3)
    }

    @Test func aWaitingAgentIsNotInterrupted() {
        // Waiting on the user, or done: the turn is over, nothing is lost by hanging the process up.
        #expect(CloseGuard.taskRisks(TaskFacts(threads: [.waiting(reason: .input), .done, .failed])).isEmpty)
    }

    @Test func thePreferenceOffNeverAsks() {
        #expect(!CloseGuard.shouldConfirm([.interruptsTurn, .uncommittedChanges], preference: false))
        #expect(CloseGuard.shouldConfirm([.interruptsTurn], preference: true))
        #expect(!CloseGuard.shouldConfirm([], preference: true))
    }

    // MARK: Reopening

    @Test func aReopenedThreadResumesItsSessionWhenTheDriverCan() throws {
        let claude = try JSONDecoder().decode(DriverProfile.self, from: Data(
            #"{"id":"claude-code","name":"Claude Code","command":"claude","resume":["claude","--resume","{resume_id}"]}"#.utf8))
        #expect(claude.canResume)
        #expect(LaunchMode.relaunch(profile: claude, resumeID: "4787d591-d8e9-4025-ba52-9e9c7fc76915") == .resume)
        #expect(LaunchMode.relaunch(profile: claude, resumeID: nil) == .launch)
        let shell = try JSONDecoder().decode(DriverProfile.self, from: Data(#"{"id":"shell","name":"Shell","command":"zsh"}"#.utf8))
        #expect(LaunchMode.relaunch(profile: shell, resumeID: "anything") == .launch)
    }
}

@Suite struct UndoLedgerTests {
    enum Action: Equatable { case thread(String), task(String) }

    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func popHandsBackTheNewestActionInsideItsWindow() {
        var ledger = UndoLedger<Action>(window: 300)
        ledger.push(id: "a", entry: .task("a"), at: t0)
        ledger.push(id: "b", entry: .thread("b"), at: t0.addingTimeInterval(10))
        #expect(ledger.pop(at: t0.addingTimeInterval(20)) == .thread("b"))
        #expect(ledger.pop(at: t0.addingTimeInterval(20)) == .task("a"))
        #expect(ledger.pop(at: t0.addingTimeInterval(20)) == nil)
    }

    @Test func anExpiredActionIsGoneAndDoesNotShadowAnOlderLiveOne() {
        var ledger = UndoLedger<Action>(window: 300)
        ledger.push(id: "old", entry: .task("old"), at: t0)
        ledger.push(id: "new", entry: .thread("new"), at: t0.addingTimeInterval(100))
        // 300 s after "old", 200 s after "new": only "new" is left.
        #expect(ledger.live(at: t0.addingTimeInterval(300)).map(\.id) == ["new"])
        #expect(ledger.pop(at: t0.addingTimeInterval(300)) == .thread("new"))
        #expect(ledger.isEmpty(at: t0.addingTimeInterval(300)))
    }

    @Test func aFilteredPopSkipsTheOtherKind() {
        var ledger = UndoLedger<Action>(window: 300)
        ledger.push(id: "thread", entry: .thread("t"), at: t0)
        ledger.push(id: "task", entry: .task("k"), at: t0.addingTimeInterval(1))
        let reopened = ledger.pop(at: t0.addingTimeInterval(2)) { if case .thread = $0 { true } else { false } }
        #expect(reopened == .thread("t"))
        #expect(ledger.items.map(\.id) == ["task"])
    }

    @Test func aToastTakesItsOwnActionAndTheSameIdReplacesAnEarlierOne() {
        var ledger = UndoLedger<Action>(window: 300)
        ledger.push(id: "x", entry: .thread("first"), at: t0)
        ledger.push(id: "y", entry: .task("y"), at: t0.addingTimeInterval(1))
        ledger.push(id: "x", entry: .thread("second"), at: t0.addingTimeInterval(2))
        #expect(ledger.items.map(\.id) == ["y", "x"])
        #expect(ledger.take(id: "x", at: t0.addingTimeInterval(3)) == .thread("second"))
        #expect(ledger.take(id: "x", at: t0.addingTimeInterval(3)) == nil)
        ledger.remove(id: "y")
        #expect(ledger.isEmpty(at: t0))
    }
}
