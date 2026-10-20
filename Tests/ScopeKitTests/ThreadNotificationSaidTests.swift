import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

/// `ThreadNotificationContent.Said.from`: which words of the agent a notification quotes for an event.
@Suite struct ThreadNotificationSaidTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!

    static func event(_ kind: HookEvent.Kind, _ seconds: TimeInterval, raw: String? = nil) -> AdapterEvent {
        AdapterEvent(threadID: thread, kind: kind, raw: raw, receivedAt: Date(timeIntervalSince1970: 1_000 + seconds))
    }

    static func fold(_ events: [AdapterEvent]) -> ThreadActivity {
        events.reduce(ThreadActivity()) { $0.apply($1) }
    }

    @Test func aFinishedTurnQuotesTheAnswerItCarries() {
        let ended = Self.event(.turnEnded, 2, raw: #"{"last_assistant_message":"All done."}"#)
        let activity = Self.fold([Self.event(.turnStarted, 1), ended])
        #expect(ThreadNotificationContent.Said.from(ended, activity: activity) == .reply("All done."))
    }

    @Test func aFinishedTurnWithoutAnAnswerQuotesNothingOlder() {
        let first = Self.event(.turnEnded, 2, raw: #"{"last_assistant_message":"Old answer"}"#)
        let second = Self.event(.turnEnded, 4)
        let activity = Self.fold([Self.event(.turnStarted, 1), first, Self.event(.turnStarted, 3), second])
        #expect(ThreadNotificationContent.Said.from(second, activity: activity) == nil)
    }

    @Test func aQuestionToolQuotesItsQuestion() {
        let ask = Self.event(.inputRequested, 2, raw: #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?"}]}}"#)
        let activity = Self.fold([Self.event(.turnStarted, 1), ask])
        #expect(ThreadNotificationContent.Said.from(ask, activity: activity) == .question("Ship it?"))
    }

    @Test func aQuestionWithoutWordsQuotesTheAnswerJustGiven() {
        let ended = Self.event(.turnEnded, 2, raw: #"{"last_assistant_message":"Should I merge?"}"#)
        let input = Self.event(.inputRequested, 3, raw: #"{"notification_type":"agent_needs_input"}"#)
        let activity = Self.fold([Self.event(.turnStarted, 1), ended, input])
        #expect(ThreadNotificationContent.Said.from(input, activity: activity) == .reply("Should I merge?"))
    }

    @Test func anAnswerFromBeforeTheTurnIsNotQuoted() {
        let ended = Self.event(.turnEnded, 2, raw: #"{"last_assistant_message":"Earlier answer"}"#)
        let input = Self.event(.inputRequested, 4)
        let activity = Self.fold([Self.event(.turnStarted, 1), ended, Self.event(.turnStarted, 3), input])
        #expect(ThreadNotificationContent.Said.from(input, activity: activity) == nil)
    }

    static func pending(_ payloads: [String]) -> ClaudePendingRequest? {
        var pending = ClaudePendingRequests()
        for payload in payloads {
            guard let body = JSONValue(json: payload) else { continue }
            pending.apply(ClaudeHookFacts(body: body, at: Date(timeIntervalSince1970: 1_000)))
        }
        return pending.current
    }

    @Test func aPermissionQuotesTheCommandOrWhatItUses() {
        let prompt = Self.event(.permissionRequested, 2)
        let bash = Self.pending(Array(ClaudePendingFixtures.bash[2...3]))
        #expect(ThreadNotificationContent.Said.from(prompt, activity: ThreadActivity(), pending: bash) == .request("echo probe hello"))
        let mcp = Self.pending(Array(ClaudePendingFixtures.mcp[4...5]))
        #expect(ThreadNotificationContent.Said.from(prompt, activity: ThreadActivity(), pending: mcp) == .request("probe_echo on probe"))
        // Without the session's word, a permission keeps its generic body.
        #expect(ThreadNotificationContent.Said.from(prompt, activity: ThreadActivity()) == nil)
    }

    @Test func anMCPFormQuotesItsServerAndMessage() {
        let dialog = Self.event(.inputRequested, 2, raw: ClaudePendingFixtures.elicitation[5])
        let form = Self.pending(Array(ClaudePendingFixtures.elicitation[4...5]))
        #expect(ThreadNotificationContent.Said.from(dialog, activity: ThreadActivity(), pending: form)
            == .question("probe: Pick a deployment tier"))
    }

    @Test func otherEventsQuoteNothing() {
        let failed = Self.event(.turnFailed, 2, raw: #"{"error":"rate_limit"}"#)
        #expect(ThreadNotificationContent.Said.from(failed, activity: Self.fold([failed])) == nil)
    }
}
