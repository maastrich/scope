import Foundation
import Testing
import ScopeAdapters
import ScopeCore
@testable import ScopeAssist

/// The gate every acting trigger goes through: preference, once per key, never mid-turn or over the user's typing,
/// debounce, hourly cap — the rules that keep a trigger from looping.
@Suite struct ActingTriggersTests {
    let a = ThreadID(rawValue: "aaaaaaaaaaaa")!
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let on = ActingTriggerPreference(enabled: true, hourlyCap: 2)

    func proposal(_ trigger: ActingTrigger = .ciFailed, key: String = "ci@abc",
                  action: ActingTriggers.Action = .send("go")) -> ActingTriggers.Proposal {
        .init(trigger: trigger, thread: a, key: key, action: action, cause: "failing")
    }

    func idle() -> ActingTriggers.ThreadFacts { .init(id: a) }

    @Test func anIdleThreadIsActedOn() {
        #expect(ActingTriggers.decide(proposal(), thread: idle(), preference: on, ledger: .init(), now: now) == .act)
    }

    @Test func aTriggerTurnedOffNeverActs() {
        let off = ActingTriggerPreference(enabled: false, hourlyCap: 2)
        #expect(ActingTriggers.decide(proposal(), thread: idle(), preference: off, ledger: .init(), now: now) == .skip("off"))
    }

    @Test func oneKeyIsActedOnOnceEvenHoursLater() {
        var ledger = ActingLedger()
        ledger.recordAct(.ciFailed, on: a, key: "ci@abc", at: now.addingTimeInterval(-5 * 3600))
        #expect(ActingTriggers.decide(proposal(), thread: idle(), preference: on, ledger: ledger, now: now) == .skip("done"))
        // Another SHA is another occasion.
        #expect(ActingTriggers.decide(proposal(key: "ci@def"), thread: idle(), preference: on, ledger: ledger, now: now) == .act)
    }

    @Test func neverMidTurnUnlessTheActionIsToInterrupt() {
        var busy = idle()
        busy.inTurn = true
        #expect(ActingTriggers.decide(proposal(), thread: busy, preference: on, ledger: .init(), now: now) == .hold("busy"))
        let interrupt = proposal(.stuck, key: "turn@1", action: .interrupt(then: "change approach"))
        #expect(ActingTriggers.decide(interrupt, thread: busy, preference: on, ledger: .init(), now: now) == .act)
    }

    @Test func neverWhileTheUserTypesOrOwesAnAnswer() {
        var typing = idle()
        typing.lastUserInputAt = now.addingTimeInterval(-5)
        #expect(ActingTriggers.decide(proposal(), thread: typing, preference: on, ledger: .init(), now: now) == .hold("typing"))
        typing.lastUserInputAt = now.addingTimeInterval(-ActingTriggers.typingGrace)
        #expect(ActingTriggers.decide(proposal(), thread: typing, preference: on, ledger: .init(), now: now) == .act)
        var asking = idle()
        asking.waitingForUser = true
        #expect(ActingTriggers.decide(proposal(), thread: asking, preference: on, ledger: .init(), now: now) == .hold("waiting"))
    }

    @Test func aDeadThreadIsOnlyRestartedAndOnlyWhenItCanBe() {
        var dead = idle()
        dead.alive = false
        #expect(ActingTriggers.decide(proposal(), thread: dead, preference: on, ledger: .init(), now: now) == .skip("no-thread"))
        let restart = proposal(.wake, key: "wake@1", action: .restart(note: "go on"))
        #expect(ActingTriggers.decide(restart, thread: dead, preference: on, ledger: .init(), now: now) == .skip("no-thread"))
        dead.canRestart = true
        // A dead thread's last turn is still "open" in its activity: that must not read as busy.
        dead.inTurn = true
        #expect(ActingTriggers.decide(restart, thread: dead, preference: on, ledger: .init(), now: now) == .act)
        #expect(ActingTriggers.decide(proposal(), thread: nil, preference: on, ledger: .init(), now: now) == .skip("no-thread"))
    }

    @Test func actsOfOneTriggerAreDebounced() {
        var ledger = ActingLedger()
        ledger.recordAct(.connectionLost, on: a, key: "fail@1", at: now.addingTimeInterval(-10))
        let next = proposal(.connectionLost, key: "fail@2")
        #expect(ActingTriggers.decide(next, thread: idle(), preference: on, ledger: ledger, now: now) == .hold("debounce"))
        #expect(ActingTriggers.decide(next, thread: idle(), preference: on, ledger: ledger,
                                      now: now.addingTimeInterval(ActingTriggers.debounce(.connectionLost))) == .act)
    }

    /// A network that keeps failing the relaunched turn: the cap stops it, whatever the keys.
    @Test func theHourlyCapStopsALoopOfNewKeys() {
        var ledger = ActingLedger()
        var clock = now
        var acted = 0
        for attempt in 0..<10 {
            let p = proposal(.connectionLost, key: "fail@\(attempt)")
            switch ActingTriggers.decide(p, thread: idle(), preference: on, ledger: ledger, now: clock) {
            case .act:
                acted += 1
                ledger.recordAct(.connectionLost, on: a, key: p.key, at: clock)
            case .capped:
                break
            default:
                Issue.record("unexpected verdict")
            }
            clock = clock.addingTimeInterval(60)
        }
        #expect(acted == 2)
        // An hour after the first act, one more is allowed.
        #expect(ActingTriggers.decide(proposal(.connectionLost, key: "fail@x"), thread: idle(), preference: on,
                                      ledger: ledger, now: now.addingTimeInterval(3601)) == .act)
    }

    @Test func theCapIsPerTrigger() {
        var ledger = ActingLedger()
        ledger.recordAct(.ciFailed, on: a, key: "ci@1", at: now.addingTimeInterval(-1000))
        ledger.recordAct(.ciFailed, on: a, key: "ci@2", at: now.addingTimeInterval(-600))
        #expect(ActingTriggers.decide(proposal(key: "ci@3"), thread: idle(), preference: on, ledger: ledger, now: now) == .capped)
        #expect(ActingTriggers.decide(proposal(.review, key: "review@1"), thread: idle(), preference: on, ledger: ledger, now: now) == .act)
    }

    /// The turn Scope's own "change approach" message opened is not judged stuck again by the same trigger.
    @Test func aStuckRelaunchNeverRelaunchesItsOwnTurn() {
        var facts = idle()
        facts.inTurn = true
        facts.turnOpenedBy = .stuck
        let p = proposal(.stuck, key: "turn@2", action: .interrupt(then: "x"))
        #expect(ActingTriggers.decide(p, thread: facts, preference: on, ledger: .init(), now: now) == .skip("own-turn"))
        facts.turnOpenedBy = .ciFailed
        #expect(ActingTriggers.decide(p, thread: facts, preference: on, ledger: .init(), now: now) == .act)
    }

    @Test func theLedgerRoundTripsAndForgetsOldEntries() throws {
        var ledger = ActingLedger()
        ledger.recordAct(.review, on: a, key: "review@1", at: now.addingTimeInterval(-ActingLedger.retention - 10))
        ledger.recordAct(.review, on: a, key: "review@2", at: now)
        ledger.recordNotice(.review, on: a, key: ActingLedger.capKey(at: now), at: now)
        ledger.setMark(.review, "task1", to: now)
        #expect(ledger.acts.map(\.key) == ["review@2"])
        let data = try ActingLedgerStore.encoder.encode(ledger)
        let back = try ActingLedgerStore.decoder.decode(ActingLedger.self, from: data)
        #expect(back.acts.map(\.key) == ["review@2"])
        #expect(back.hasNotified(.review, on: a, key: ActingLedger.capKey(at: now)))
        #expect(back.mark(.review, "task1") != nil)
        // A ledger from before marks existed still decodes.
        let old = try ActingLedgerStore.decoder.decode(ActingLedger.self, from: Data(#"{"acts":[],"notices":[]}"#.utf8))
        #expect(old.marks == nil)
    }

    @Test func theStoreKeepsTheLedgerAcrossLaunches() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "acting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ActingLedgerStore(home: home)
        var ledger = await store.load()
        #expect(ledger.acts.isEmpty)
        ledger.recordAct(.ciFailed, on: a, key: "ci@abc", at: now)
        await store.save(ledger)
        let again = await ActingLedgerStore(home: home).load()
        #expect(again.hasActed(.ciFailed, on: a, key: "ci@abc"))
    }

    // MARK: Preferences

    @Test func preferencesDefaultSafelyAndDecodeFromAnOldConfig() throws {
        let prefs = ActingTriggerPreferences()
        for trigger in ActingTrigger.allCases {
            #expect(prefs[trigger].enabled)
            #expect(prefs[trigger].hourlyCap <= 3)
        }
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(old.actingTriggers == ActingTriggerPreferences())
        var changed = Preferences()
        changed.actingTriggers[.stuck] = ActingTriggerPreference(enabled: false, hourlyCap: 1)
        changed.actingTriggers[.review] = ActingTriggerPreference(enabled: true, hourlyCap: 99)
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(back.actingTriggers[.stuck] == ActingTriggerPreference(enabled: false, hourlyCap: 1))
        #expect(back.actingTriggers[.review].hourlyCap == ActingTriggerPreference.capRange.upperBound)
        #expect(back.actingTriggers[.ciFailed] == ActingTriggerPreferences.defaultPreference(.ciFailed))
        // An unknown trigger in a newer config is dropped, not fatal.
        let newer = try JSONDecoder().decode(ActingTriggerPreferences.self,
                                             from: Data(#"{"future":{"enabled":false,"hourlyCap":1}}"#.utf8))
        #expect(newer == ActingTriggerPreferences())
    }

    // MARK: Messages

    @Test(arguments: ActingTrigger.allCases)
    func everyMessageSaysItComesFromScope(_ trigger: ActingTrigger) {
        let text: String = switch trigger {
        case .connectionLost: ActingPrompts.connectionBack(error: "API Error: Unable to connect to API (ECONNREFUSED)")
        case .wake: ActingPrompts.afterWake(error: nil, restarted: true)
        case .usageLimit: ActingPrompts.limitReset(resetsAt: now, throttled: false)
        case .conflicts: ActingPrompts.conflicts(pullRequest: 12, base: "main", branch: "feat/x", paths: ["a.swift"], rebaseStopped: false)
        case .ciFailed: ActingPrompts.checksFailed(pullRequest: 12, head: "abcdef123", checks: [.init(title: "CI / test", url: nil)])
        case .review: ActingPrompts.review(pullRequest: 12, comments: [.init(author: "Copilot", location: "a.swift:3", excerpt: "nit")])
        case .baseMoved: ActingPrompts.baseMoved(base: "main", branch: "feat/x", files: ["a.swift"], pullRequest: 12)
        case .stuck: ActingPrompts.stuck(reason: "edits the same file back and forth")
        }
        #expect(text.hasPrefix("[Scope: automatic message from Scope itself, not the user — \(trigger.title.lowercased())]"))
        #expect(!text.contains("--force"))
    }

    @Test func theCheckMessageNamesEachFailedJobWithItsLink() {
        let url = URL(string: "https://github.com/o/r/actions/runs/1/job/2?pr=12")!
        let text = ActingPrompts.checksFailed(pullRequest: 12, head: "abcdef123456",
                                              checks: [.init(title: "CI / test", url: url), .init(title: "lint", url: nil)])
        #expect(text.contains("- CI / test — https://github.com/o/r/actions/runs/1/job/2?pr=12"))
        #expect(text.contains("- lint\n"))
        #expect(text.contains("head abcdef1"))
        #expect(text.contains("rerun it once"))
    }

    @Test func theConnectionMessageQuotesTheErrorOnOneLine() {
        let text = ActingPrompts.connectionBack(error: "API Error: Connection dropped (ECONNRESET)\nmore")
        #expect(text.contains("(“API Error: Connection dropped (ECONNRESET)”)"))
        #expect(!text.contains("more"))
    }
}
