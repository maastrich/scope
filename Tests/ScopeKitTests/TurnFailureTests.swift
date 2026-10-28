import Foundation
import Testing
import ScopeAdapters
import ScopeCore
@testable import ScopeAssist

/// How a `StopFailure` is read. The words are Claude Code 2.1.312's own (`cwe()` and `p4o()` in its bundle): a
/// network failure comes as `unknown` or `server_error`, never as a code of its own.
@Suite struct TurnFailureTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test(arguments: [
        ("unknown", "API Error: Unable to connect to API (ECONNREFUSED)", "refused"),
        ("unknown", "API Error: Unable to connect to API. Check your internet connection", "unreachable"),
        ("unknown", "API Error: Connection dropped (ECONNRESET)", "dropped"),
        ("unknown", "API Error: Connection refused — a firewall or proxy may be blocking", "refused"),
        ("unknown", "API Error: Connection lost while your computer was asleep", "asleep"),
        ("unknown", "API Error: Connection closed before the response finished", "dropped"),
        ("unknown", "API Error: No response from API", "no-response"),
        ("server_error", "Request timed out", "timeout"),
        ("unknown", "API Error: Connection error.", "unreachable"),
        ("unknown", "API Error: getaddrinfo ENOTFOUND api.anthropic.com", "dns"),
        ("unknown", "API Error: Couldn't connect through your proxy (ECONNREFUSED)", "proxy"),
        // A stream cut mid-response: seen on a real thread of this task, 2026-10-28.
        ("server_error", "API Error: The response stopped arriving. The response above may be incomplete.", "stalled"),
        ("server_error", "API Error: The response stalled before a response was produced. Try again.", "stalled"),
        ("server_error", "API Error: Connection lost mid-response. The response above may be incomplete.", "lost"),
        ("server_error", "API Error: Your computer went to sleep before a response was produced. Try again.", "asleep"),
        ("server_error", "API Error: Part of the response never arrived. The response above may be incomplete.", "dropped"),
    ])
    func connectionErrorsAreNetwork(_ code: String, _ message: String, _ cause: String) {
        #expect(TurnFailure.classify(error: code, message: message, now: now) == .network(cause))
    }

    @Test func aNetworkErrorWithoutAnyCodeIsStillNetwork() {
        #expect(TurnFailure.classify(error: nil, message: "API Error: Connection dropped (EPIPE)") == .network("dropped"))
    }

    @Test(arguments: [
        ("authentication_failed", "Failed to authenticate: OAuth session expired"),
        ("billing_error", "Credit balance is too low"),
        ("invalid_request", "API Error: Unable to connect to API (ECONNREFUSED)"),
        ("max_output_tokens", "Claude's response exceeded the output token maximum"),
        ("model_not_found", "There's an issue with the selected model"),
        ("overloaded", "Opus is experiencing high load"),
        ("unknown", "API Error: Unable to connect to API: SSL certificate verification failed"),
        ("unknown", "API Error: something else entirely"),
        ("server_error", "API Error: Server error mid-response. The response above may be incomplete."),
    ])
    func realErrorsAreNeverRelaunched(_ code: String, _ message: String) {
        guard case .other = TurnFailure.classify(error: code, message: message, now: now) else {
            Issue.record("\(code): \(message) read as relaunchable")
            return
        }
    }

    @Test func aServerAskingToSlowDownIsNotTheUsageLimit() {
        let text = "API Error: Server is temporarily limiting requests (not your usage limit) · this may be a temporary capacity issue."
        #expect(TurnFailure.classify(error: "rate_limit", message: text, now: now) == .throttled)
    }

    @Test func theUsageLimitResetsWhenTheFullWindowSaysSo() {
        let reset = now.addingTimeInterval(3 * 3600)
        let windows = [TurnFailure.Window(usedPercentage: 100, resetsAt: reset),
                       TurnFailure.Window(usedPercentage: 40, resetsAt: now.addingTimeInterval(86_400))]
        #expect(TurnFailure.classify(error: "rate_limit", message: "You've hit your limit", windows: windows, now: now)
                == .usageLimit(resetsAt: reset))
        // Both full: the later reset is the one that matters.
        let both = windows.map { TurnFailure.Window(usedPercentage: 101, resetsAt: $0.resetsAt) }
        #expect(TurnFailure.classify(error: "rate_limit", message: nil, windows: both, now: now)
                == .usageLimit(resetsAt: now.addingTimeInterval(86_400)))
    }

    @Test func theUsageLimitResetIsReadFromTheMessage() throws {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let reset = try #require(TurnFailure.resetTime(in: "You've hit your limit · resets 3pm (Europe/Paris)", now: now))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        #expect(calendar.component(.hour, from: reset) == 15)
        #expect(reset > now && reset.timeIntervalSince(now) <= 86_400)
        let utc = try #require(TurnFailure.resetTime(in: "spend limit reached (daily; resets 2026-11-08 00:00 UTC)", now: now))
        #expect(utc == ISO8601DateFormatter().date(from: "2026-11-08T00:00:00Z"))
        let relative = try #require(TurnFailure.resetTime(in: "limit reached, resets in 2h 15m", now: now))
        #expect(relative == now.addingTimeInterval(2 * 3600 + 15 * 60))
        #expect(TurnFailure.resetTime(in: "no time here", now: now) == nil)
        let half = try #require(TurnFailure.resetTime(in: "resets 12:30am", now: now, timeZone: paris))
        #expect(calendar.component(.hour, from: half) == 0 && calendar.component(.minute, from: half) == 30)
    }

    @Test func aLimitWithoutAResetIsStillTheLimit() {
        #expect(TurnFailure.classify(error: "rate_limit", message: "You've hit your limit", now: now) == .usageLimit(resetsAt: nil))
    }

    @Test func causesAreJournalTokens() {
        for failure in [TurnFailure.network("dns"), .usageLimit(resetsAt: nil), .throttled, .other("billing_error"), .other("")] {
            #expect(JournalEvent.token(failure.cause) == failure.cause)
        }
    }

    // MARK: Timing

    @Test func aRelaunchWaitsForTheNetworkThenItsSettling() {
        let failed = now
        #expect(RelaunchTiming.networkRelaunch(failedAt: failed, attempt: 0, network: .init(online: false, changedAt: now)) == nil)
        let back = now.addingTimeInterval(40)
        #expect(RelaunchTiming.networkRelaunch(failedAt: failed, attempt: 0, network: .init(online: true, changedAt: back))
                == back.addingTimeInterval(RelaunchTiming.networkSettle))
    }

    @Test func aBlipTheMonitorNeverSawBacksOff() {
        let network = RelaunchTiming.Network(online: true, changedAt: now.addingTimeInterval(-3600))
        #expect(RelaunchTiming.networkRelaunch(failedAt: now, attempt: 0, network: network) == now.addingTimeInterval(30))
        #expect(RelaunchTiming.networkRelaunch(failedAt: now, attempt: 1, network: network) == now.addingTimeInterval(120))
        #expect(RelaunchTiming.networkRelaunch(failedAt: now, attempt: 9, network: network) == now.addingTimeInterval(600))
    }

    @Test func aLimitRelaunchWaitsForTheResetOrBacksOff() {
        let reset = now.addingTimeInterval(7200)
        #expect(RelaunchTiming.limitRelaunch(failedAt: now, resetsAt: reset, throttled: false, attempt: 0)
                == reset.addingTimeInterval(RelaunchTiming.resetMargin))
        #expect(RelaunchTiming.limitRelaunch(failedAt: now, resetsAt: nil, throttled: false, attempt: 0) == now.addingTimeInterval(900))
        #expect(RelaunchTiming.limitRelaunch(failedAt: now, resetsAt: nil, throttled: false, attempt: 5) == now.addingTimeInterval(3600))
        #expect(RelaunchTiming.limitRelaunch(failedAt: now, resetsAt: nil, throttled: true, attempt: 0) == now.addingTimeInterval(60))
    }

    @Test func onlyAThreadThatDiedMidTurnDuringTheSleepIsTheWakesToRelaunch() {
        let slept = now
        #expect(RelaunchTiming.diedDuringSleep(exitedAt: now.addingTimeInterval(600), turnCutShort: true, sleptAt: slept))
        // The sleep notification comes late: an exit just before it still counts.
        #expect(RelaunchTiming.diedDuringSleep(exitedAt: now.addingTimeInterval(-30), turnCutShort: true, sleptAt: slept))
        #expect(!RelaunchTiming.diedDuringSleep(exitedAt: now.addingTimeInterval(-3600), turnCutShort: true, sleptAt: slept))
        #expect(!RelaunchTiming.diedDuringSleep(exitedAt: now.addingTimeInterval(600), turnCutShort: false, sleptAt: slept))
        #expect(!RelaunchTiming.diedDuringSleep(exitedAt: nil, turnCutShort: true, sleptAt: slept))
        #expect(RelaunchTiming.failedDuringSleep(failedAt: now.addingTimeInterval(5), sleptAt: slept))
        #expect(!RelaunchTiming.failedDuringSleep(failedAt: now, sleptAt: nil))
    }

    // MARK: Hook payload

    @Test func theFailureWordsComeFromThePayloadOrFromRaw() {
        let thread = ThreadID(rawValue: "aaaaaaaaaaaa")!
        let lifted = AdapterEvent(threadID: thread, kind: .turnFailed, payload: [HookEvent.failureKey: "API Error: x"])
        #expect(HookEvent.failureWords(lifted) == "API Error: x")
        let raw = #"{"hook_event_name":"StopFailure","error":"unknown","error_details":"ECONNRESET","last_assistant_message":"API Error: Connection dropped (ECONNRESET)"}"#
        let fromRaw = AdapterEvent(threadID: thread, kind: .turnFailed, payload: [:], raw: raw)
        #expect(HookEvent.failureWords(fromRaw) == "API Error: Connection dropped (ECONNRESET)\nECONNRESET")
        #expect(HookStdin.parse(Data(raw.utf8)).errorDetails == "ECONNRESET")
    }
}
