import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

/// A turn that ended stays ended: hook events that belong to it, or to background work after it, reach the app after
/// `Stop` and must not put the thread back to `running` (`ThreadActivity.isLate`, `ThreadStateMachine.next(_:on:after:)`).
@Suite struct LateHookEventTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!

    static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    /// An event sent by the driver at `sent` and received at `received` (by default at once).
    static func event(_ kind: HookEvent.Kind, _ sent: TimeInterval, received: TimeInterval? = nil,
                      _ payload: [String: String] = [:]) -> AdapterEvent {
        AdapterEvent(threadID: thread, kind: kind, payload: payload, sentAt: at(sent), receivedAt: at(received ?? sent))
    }

    static func prompt(_ sent: TimeInterval, received: TimeInterval? = nil) -> AdapterEvent {
        event(.turnStarted, sent, received: received)
    }

    /// `PostToolUse`.
    static func tool(_ name: String, _ sent: TimeInterval, received: TimeInterval? = nil) -> AdapterEvent {
        event(.turnStarted, sent, received: received, [HookEvent.toolKey: name])
    }

    static func stop(_ sent: TimeInterval) -> AdapterEvent {
        event(.turnEnded, sent, [HookEvent.replyKey: "Done."])
    }

    /// What `ThreadSession.apply` does with each event: the state decided on the activity before the event.
    struct Replay {
        var state = ThreadState.initial
        var activity = ThreadActivity()

        mutating func feed(_ events: AdapterEvent...) {
            for event in events {
                state = ThreadStateMachine.next(state, on: event, after: activity)
                activity = activity.apply(event)
            }
        }
    }

    /// The bug seen live: a background command's `PostToolUse` after `Stop` reopened the turn for good.
    @Test func aToolReportAfterStopLeavesTheThreadDone() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.tool("Bash", 1), Self.stop(2), Self.tool("Bash", 30))
        #expect(replay.state == .done)
        #expect(!replay.activity.inTurn, "no phantom turn either")
        #expect(replay.activity.turns.count == 1)
        #expect(replay.activity.lastTool?.at == Self.at(30), "still the last thing the agent ran")
    }

    @Test func aToolReportAfterAFailedTurnLeavesItFailed() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.event(.turnFailed, 2, [HookEvent.errorKey: "rate_limit"]), Self.tool("Bash", 3))
        #expect(replay.state == .failed)
    }

    /// Looking at a finished thread turns `done` into `idle`; a late report must not take it from there either.
    @Test func aToolReportAfterTheResultWasSeenLeavesItIdle() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(2))
        replay.state = replay.state.acknowledged
        replay.feed(Self.tool("Bash", 5))
        #expect(replay.state == .idle)
    }

    /// A permission prompt for a call already decided (auto mode), notified after the turn ended: nobody is asked.
    @Test func aRequestAfterStopLeavesTheThreadDone() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(2),
                    Self.event(.permissionRequested, 3, [HookEvent.viaKey: HookEvent.viaNotification]))
        #expect(replay.state == .done)
        replay.feed(Self.event(.inputRequested, 4))
        #expect(replay.state == .done)
        #expect(replay.activity.pendingRequest == nil)
    }

    /// Each hook is its own connection: one sent before `Stop` can still be delivered after it.
    @Test func anEventSentBeforeStopButDeliveredAfterItChangesNothing() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(5), Self.tool("Edit", 4, received: 6))
        #expect(replay.state == .done)
        replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(5), Self.prompt(1, received: 7))
        #expect(replay.state == .done, "even the turn's own prompt, delivered last")
        #expect(replay.activity.turns.count == 1)
    }

    /// A new prompt is a new turn — a background task's completion included, which Claude Code also submits as a
    /// prompt (`UserPromptSubmit` fires for its `<task-notification>`).
    @Test func aPromptAfterStopStartsTheNextTurn() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(2), Self.prompt(10))
        #expect(replay.state == .running)
        replay.feed(Self.tool("Bash", 11))
        #expect(replay.state == .running)
        #expect(replay.activity.turnTools == 1)
        replay.feed(Self.stop(12))
        #expect(replay.state == .done)
        #expect(replay.activity.turns.count == 2)
    }

    @Test func aGrantedPermissionGoesOnWithItsTool() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.event(.permissionRequested, 1, [HookEvent.toolKey: "Bash"]))
        #expect(replay.state == .waiting(reason: .permission))
        replay.feed(Self.tool("Bash", 20))
        #expect(replay.state == .running)
    }

    @Test func anAnsweredQuestionGoesOnWithItsTool() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.event(.inputRequested, 1, [HookEvent.toolKey: "AskUserQuestion"]))
        #expect(replay.state == .waiting(reason: .input))
        replay.feed(Self.tool("AskUserQuestion", 20))
        #expect(replay.state == .running)
    }

    /// Esc has no hook and may have been swallowed by a menu: should the agent go on, its next tool says so.
    @Test func aToolAfterAnInterruptResumesTheTurn() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.tool("Read", 1))
        replay.activity = replay.activity.closingOpenTurn(as: .interrupted, at: Self.at(2))
        replay.state = ThreadStateMachine.next(replay.state, onUserInput: .interrupt, adapterReportsTurnStart: true) ?? replay.state
        #expect(replay.state == .idle)
        replay.feed(Self.tool("Edit", 3))
        #expect(replay.state == .running)
    }

    /// Most likely what held the thread seen live: nothing ran after `Stop`, yet it read `running`. A permission
    /// prompt notified after the turn (auto mode had decided it) showed `waiting`; Return on it meant "approved".
    @Test func aStalePermissionThenReturnDoesNotReopenTheTurn() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(2),
                    Self.event(.permissionRequested, 3, [HookEvent.viaKey: HookEvent.viaNotification]))
        if let next = ThreadStateMachine.next(replay.state, onUserInput: .submit(hadText: false), adapterReportsTurnStart: true) {
            replay.state = next
        }
        #expect(replay.state == .done)
    }

    /// `idle_prompt` comes a minute after any unanswered reply: it sends nothing at all.
    @Test func anIdlePromptAfterStopSendsNothing() {
        #expect(HookCommandEvent.notification.resolve(stdin: HookStdin(notificationType: "idle_prompt")) == nil)
    }

    /// Scope just handed a prompt and its `UserPromptSubmit` hook got lost: the tools are the only sign of the work.
    @Test func aToolWhileAPromptIsPendingStartsTheTurn() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(2))
        let tool = Self.tool("Bash", 10)
        #expect(ThreadStateMachine.next(replay.state, on: tool, after: replay.activity, promptPending: true) == .running)
        #expect(replay.activity.apply(tool, promptPending: true).inTurn)
        // Still nothing sent before the end of the last turn.
        #expect(replay.activity.isLate(Self.tool("Bash", 1, received: 11), promptPending: true))
    }

    /// No history to go by (a fresh session, a restart): a tool report still means work.
    @Test func aToolWithNoHistoryMeansWork() {
        var replay = Replay()
        replay.feed(Self.tool("Bash", 0))
        #expect(replay.state == .running)
    }

    @Test func theEndOfATurnIsKeptAcrossARestart() {
        var replay = Replay()
        replay.feed(Self.prompt(0), Self.stop(5))
        let restored = ThreadActivity().restoring(replay.activity)
        #expect(restored.turnEndSentAt == Self.at(5))
        #expect(restored.isLate(Self.tool("Edit", 4, received: 9)))
    }
}
