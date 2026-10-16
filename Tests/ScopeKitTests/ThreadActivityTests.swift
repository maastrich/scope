import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters
@testable import ScopeControl

/// `ThreadActivity`: the fold of a thread's adapter events, its file, and the line `scope list` prints from it.
@Suite struct ThreadActivityTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!

    static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    static func event(_ kind: HookEvent.Kind, _ seconds: TimeInterval, _ payload: [String: String] = [:],
                      raw: String? = nil) -> AdapterEvent {
        AdapterEvent(threadID: thread, kind: kind, payload: payload, raw: raw, receivedAt: at(seconds))
    }

    static func tool(_ name: String, _ target: String?, _ seconds: TimeInterval) -> AdapterEvent {
        var payload = [HookEvent.toolKey: name]
        payload[HookEvent.targetKey] = target
        return event(.turnStarted, seconds, payload)
    }

    static func fold(_ events: [AdapterEvent], from start: ThreadActivity = ThreadActivity()) -> ThreadActivity {
        events.reduce(start) { $0.apply($1) }
    }

    // MARK: Reducer

    @Test func aPromptOpensATurnAndToolsRunInsideIt() {
        let activity = Self.fold([
            Self.event(.sessionStarted, 0, [HookEvent.transcriptKey: "/t/9b1d.jsonl"]),
            Self.event(.turnStarted, 1),
            Self.tool("Read", "/w/a.swift", 2),
            Self.tool("Edit", "/w/a.swift", 3),
        ])
        #expect(activity.turnStartedAt == Self.at(1))
        #expect(activity.turnTools == 2)
        #expect(activity.lastTool == .init(name: "Edit", target: "/w/a.swift", at: Self.at(3)))
        #expect(activity.turns.isEmpty)
        #expect(activity.transcriptPath == "/t/9b1d.jsonl")
    }

    @Test func theAnswerBeingWrittenGrowsFlushByFlushAndGoesWithTheTurn() {
        func said(_ text: String, _ message: String, _ seconds: TimeInterval, final: Bool = false) -> AdapterEvent {
            var payload = [HookEvent.saidKey: text, HookEvent.messageKey: message]
            if final { payload[HookEvent.finalKey] = "true" }
            return Self.event(.turnSaid, seconds, payload)
        }
        var activity = Self.fold([Self.event(.turnStarted, 0), said("Reading the adapter.\n", "m1", 1),
                                  said("Found it.\n", "m1", 2, final: true)])
        #expect(activity.saying?.text == "Reading the adapter.\nFound it.\n")
        #expect(activity.saying?.isFinal == true)
        #expect(activity.saying?.at == Self.at(2))
        // A piece of the answer neither opens a turn nor counts as a tool, nor touches a pending request.
        #expect(activity.inTurn && activity.turnTools == 0 && activity.turns.isEmpty)

        // The next message of the same turn starts the text over: the column shows the message in progress.
        activity = Self.fold([Self.tool("Edit", "A.swift", 3), said("Done, ", "m2", 4)], from: activity)
        #expect(activity.saying?.text == "Done, ")
        #expect(activity.turnTools == 1)

        // The turn's end has the answer in `lastReply`; the text being written is gone with it.
        let ended = Self.fold([Self.event(.turnEnded, 5, [HookEvent.replyKey: "Done, tested."])], from: activity)
        #expect(ended.saying == nil)
        #expect(ended.lastReply?.text == "Done, tested.")
        #expect(ended.turns.last?.said == "Done, tested.")

        // So is a new prompt, and a question: what is shown then is the question, not a stale draft.
        #expect(Self.fold([Self.event(.turnStarted, 5)], from: activity).saying == nil)
        #expect(Self.fold([Self.event(.inputRequested, 5, [HookEvent.toolKey: "AskUserQuestion"])], from: activity).saying == nil)
    }

    @Test func theAnswerBeingWrittenIsNeitherSavedNorUnbounded() throws {
        let long = String(repeating: "x", count: ThreadActivity.sayingLimit + 10)
        let activity = Self.fold([Self.event(.turnStarted, 0), Self.event(.turnSaid, 1, [HookEvent.saidKey: long])])
        let text = try #require(activity.saying?.text)
        #expect(text.hasPrefix("…") && text.utf8.count <= ThreadActivity.sayingLimit)
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(activity)
        #expect(!String(decoding: data, as: UTF8.self).contains("saying"))
        let back = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadActivity.self, from: data)
        #expect(back.saying == nil && back.inTurn)
    }

    @Test func theEndOfATurnRecordsItAndItsReply() {
        let activity = Self.fold([
            Self.event(.turnStarted, 1),
            Self.tool("Bash", "swift build", 2),
            Self.event(.turnEnded, 9, raw: #"{"last_assistant_message":"Built."}"#),
        ])
        #expect(!activity.inTurn)
        #expect(activity.turns == [.init(startedAt: Self.at(1), endedAt: Self.at(9), outcome: .ended, tools: 1, said: "Built.")])
        #expect(activity.lastReply == AgentReply(text: "Built.", at: Self.at(9)))
        #expect(activity.lastTool?.name == "Bash", "the last tool outlives its turn")
    }

    @Test func eachTurnKeepsTheOpeningOfItsOwnReplyOnly() {
        let long = String(repeating: "word ", count: 60) + "end"
        let activity = Self.fold([
            Self.event(.turnStarted, 1),
            Self.event(.turnEnded, 9, raw: #"{"last_assistant_message":"\#(long)"}"#),
            Self.event(.turnStarted, 20),
            Self.event(.inputRequested, 25),
        ])
        let said = activity.turns[0].said ?? ""
        #expect(said.hasPrefix("word word"))
        #expect(said.hasSuffix("…"))
        #expect(said.count <= ThreadActivity.saidLimit + 1)
        #expect(ThreadActivity.excerpt("Done.\n\n  Next:  tests") == "Done. Next: tests")
        #expect(activity.turns[1].said == nil, "the reply of the turn before is not this one's")
        #expect(ThreadActivity.excerpt("  \n ") == nil)
    }

    @Test func eachWayATurnEndsIsKept() {
        let failed = Self.fold([Self.event(.turnStarted, 1), Self.event(.turnFailed, 2, [HookEvent.errorKey: "rate_limit"])])
        #expect(failed.turns.last?.outcome == .failed)
        #expect(failed.turns.last?.error == "rate_limit")
        let input = Self.fold([Self.event(.turnStarted, 1), Self.event(.inputRequested, 2)])
        #expect(input.turns.last?.outcome == .inputRequested)
        let permission = Self.fold([Self.event(.turnStarted, 1), Self.event(.permissionRequested, 2, [HookEvent.toolKey: "Bash"])])
        #expect(permission.turns.last?.outcome == .permissionRequested)
        #expect(permission.lastTool == nil, "a tool asked for has not run")
        let exited = Self.fold([Self.event(.turnStarted, 1), Self.event(.threadEnded, 2)])
        #expect(exited.turns.last?.outcome == .exited)
    }

    /// Claude Code sends `PermissionRequest`, then a `Notification` for the same prompt: one wait, not two.
    @Test func aRequestBetweenTurnsIsNotAnotherTurn() {
        let activity = Self.fold([
            Self.event(.turnStarted, 1),
            Self.event(.permissionRequested, 2),
            Self.event(.permissionRequested, 3, [HookEvent.viaKey: HookEvent.viaNotification]),
            Self.event(.threadEnded, 4),
        ])
        #expect(activity.turns.map(\.outcome) == [.permissionRequested])
    }

    /// Granted, the tool runs and the agent goes on: a new stretch of work, from the tool.
    @Test func aGrantedPermissionGoesOnInANewTurn() {
        let activity = Self.fold([
            Self.event(.turnStarted, 1),
            Self.event(.permissionRequested, 2),
            Self.tool("Bash", "rm -rf build", 30),
            Self.event(.turnEnded, 40),
        ])
        #expect(activity.turns == [
            .init(startedAt: Self.at(1), endedAt: Self.at(2), outcome: .permissionRequested),
            .init(startedAt: Self.at(30), endedAt: Self.at(40), outcome: .ended, tools: 1),
        ])
    }

    /// Esc has no hook. The app closes the turn when it sees the keystroke; a turn still open at the next prompt
    /// was cut without it, and ends at the last thing it reported rather than when the user came back.
    @Test func aPromptOverAnOpenTurnInterruptsIt() {
        let activity = Self.fold([
            Self.event(.turnStarted, 1),
            Self.tool("Read", "/w/a.swift", 2),
            Self.event(.turnStarted, 3_600),
        ])
        #expect(activity.turns == [.init(startedAt: Self.at(1), endedAt: Self.at(2), outcome: .interrupted, tools: 1)])
        #expect(activity.turnStartedAt == Self.at(3_600))
        #expect(activity.turnTools == 0)
    }

    @Test func anInterruptKeystrokeClosesTheTurnThere() {
        let open = Self.fold([Self.event(.turnStarted, 1), Self.tool("Bash", "make", 2)])
        let stopped = open.closingOpenTurn(as: .interrupted, at: Self.at(4))
        #expect(stopped.turns == [.init(startedAt: Self.at(1), endedAt: Self.at(4), outcome: .interrupted, tools: 1)])
        #expect(!stopped.inTurn)
        #expect(Self.fold([Self.event(.turnStarted, 9)], from: stopped).turns.count == 1, "the next prompt adds nothing")
    }

    @Test func aPromptWithNothingOpenOnlyOpensATurn() {
        let activity = Self.fold([Self.event(.turnStarted, 5)])
        #expect(activity.turns.isEmpty)
        #expect(activity.turnStartedAt == Self.at(5))
    }

    /// Codex `notify` only ever says a turn ended.
    @Test func anEndWithoutAStartIsATurnOfUnknownStart() {
        let activity = Self.fold([Self.event(.turnEnded, 5), Self.event(.turnEnded, 9)])
        #expect(activity.turns.map(\.startedAt) == [nil, nil])
        #expect(activity.turns.map(\.endedAt) == [Self.at(5), Self.at(9)])
    }

    /// A permission denied ends the turn without a tool: it went on from the wait.
    @Test func anEndAfterAWaitStartsAtTheWait() {
        let activity = Self.fold([Self.event(.turnStarted, 1), Self.event(.permissionRequested, 2), Self.event(.turnEnded, 7)])
        #expect(activity.turns.last == .init(startedAt: Self.at(2), endedAt: Self.at(7), outcome: .ended))
    }

    @Test func theRingKeepsTheLatestTurns() {
        let events = (0..<(ThreadActivity.turnLimit + 25)).map { Self.event(.turnEnded, TimeInterval($0)) }
        let activity = Self.fold(events)
        #expect(activity.turns.count == ThreadActivity.turnLimit)
        #expect(activity.turns.first?.endedAt == Self.at(25))
        #expect(activity.turns.last?.endedAt == Self.at(TimeInterval(ThreadActivity.turnLimit + 24)))
    }

    @Test func aLongReplyKeepsItsEnd() {
        let long = String(repeating: "é", count: ThreadActivity.replyLimit) + "Conclusion."
        let activity = Self.fold([Self.event(.turnEnded, 1, [HookEvent.replyKey: long])])
        let text = activity.lastReply?.text ?? ""
        #expect(text.utf8.count <= ThreadActivity.replyLimit)
        #expect(text.hasPrefix("…é"), "a character cut in half is dropped, not shown as U+FFFD")
        #expect(text.hasSuffix("Conclusion."))
        #expect(ThreadActivity.bounded(AgentReply(text: "short", at: Self.at(0))).text == "short")
    }

    @Test func anExitClosesTheOpenTurnAtItsLastKnownMoment() {
        let open = Self.fold([Self.event(.turnStarted, 1), Self.tool("Bash", "make", 8)])
        #expect(open.closingOpenTurn(at: Self.at(3)).turns == [
            .init(startedAt: Self.at(1), endedAt: Self.at(8), outcome: .exited, tools: 1),
        ])
        #expect(ThreadActivity().closingOpenTurn(at: Self.at(3)) == ThreadActivity())
    }

    // MARK: Restart

    @Test func whatWasSavedGoesUnderWhatArrivedSince() {
        let saved = Self.fold([
            Self.event(.turnStarted, 1, [HookEvent.transcriptKey: "/t/old.jsonl"]),
            Self.event(.turnEnded, 2, [HookEvent.replyKey: "Old answer."]),
            Self.event(.turnStarted, 3),
            Self.tool("Edit", "/w/a.swift", 4),
        ])
        let since = Self.fold([Self.event(.turnStarted, 10), Self.tool("Read", "/w/b.swift", 11)])
        let merged = since.restoring(saved)
        #expect(merged.turns.map(\.outcome) == [.ended, .exited])
        #expect(merged.turns.last?.endedAt == Self.at(4), "the saved open turn ends at the last thing it saw")
        #expect(merged.turnStartedAt == Self.at(10))
        #expect(merged.lastTool?.target == "/w/b.swift")
        #expect(merged.lastReply?.text == "Old answer.")
        #expect(merged.transcriptPath == "/t/old.jsonl")
    }

    @Test func theFileRoundTripsBesideTheRecordWithoutBeingTakenForOne() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadActivityStore(home: home)
        #expect(await store.load(Self.thread) == nil)
        let activity = Self.fold([Self.event(.turnStarted, 1), Self.tool("Edit", "/w/a.swift", 2),
                                  Self.event(.turnEnded, 3, [HookEvent.replyKey: "Done."])])
        await store.save(activity, for: Self.thread)
        #expect(await store.load(Self.thread) == activity)
        #expect(store.url(for: Self.thread).lastPathComponent == "3f9a2c17be04.activity.json")
        let (records, problems) = await ThreadRecordStore(home: home).loadAll()
        #expect(records.isEmpty && problems.isEmpty)

        try Data(#"{"version":99,"turns":[]}"#.utf8).write(to: store.url(for: Self.thread))
        #expect(await store.load(Self.thread) == nil, "another schema is no activity, not an error")
        await store.delete(Self.thread)
        await store.delete(Self.thread)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: Self.thread).path))
    }
}

/// The `activity` field of `scope list`.
@Suite struct ThreadActivityLineTests {
    static let now = ThreadActivityTests.at(600)

    static func line(_ events: [AdapterEvent], cwd: String? = "/w") -> String? {
        ThreadActivityLine.text(ThreadActivityTests.fold(events), cwd: cwd, now: now)
    }

    @Test func nothingReportedIsNoLine() {
        #expect(Self.line([]) == nil)
    }

    @Test func theLastToolNamesItsTargetUnderTheThreadsFolder() {
        #expect(Self.line([ThreadActivityTests.tool("Edit", "/w/Sources/ScopeTasks/TaskTopic.swift", 480)])
                == "Edit Sources/ScopeTasks/TaskTopic.swift · 2m ago")
        #expect(Self.line([ThreadActivityTests.tool("Read", "/elsewhere/a.swift", 600)]) == "Read /elsewhere/a.swift · just now")
        #expect(Self.line([ThreadActivityTests.tool("Bash", "swift build", 590)], cwd: nil) == "Bash swift build · 10s ago")
        #expect(Self.line([ThreadActivityTests.tool("TodoWrite", nil, 540)]) == "TodoWrite · 1m ago")
    }

    @Test func aFinishedTurnOutranksTheToolBeforeIt() {
        let events = [ThreadActivityTests.event(.turnStarted, 0), ThreadActivityTests.tool("Edit", "/w/a.swift", 10),
                      ThreadActivityTests.event(.turnEnded, 10)]
        #expect(Self.line(events) == "finished · 9m ago")
        #expect(Self.line([ThreadActivityTests.event(.turnStarted, 0),
                           ThreadActivityTests.event(.turnFailed, 0, [HookEvent.errorKey: "rate_limit"])])
                == "failed (rate_limit) · 10m ago")
        #expect(Self.line([ThreadActivityTests.event(.turnStarted, 0), ThreadActivityTests.event(.permissionRequested, 0)])
                == "waiting for a permission · 10m ago")
    }

    @Test func aPromptWithNoToolYetIsWork() {
        #expect(Self.line([ThreadActivityTests.event(.turnEnded, 0), ThreadActivityTests.event(.turnStarted, 597)])
                == "working · just now")
    }

    @Test func agesRoundDown() {
        #expect(ThreadActivityLine.ago(Self.now.addingTimeInterval(30), now: Self.now) == "just now")
        #expect(ThreadActivityLine.ago(Self.now.addingTimeInterval(-7_200), now: Self.now) == "2h ago")
        #expect(ThreadActivityLine.ago(Self.now.addingTimeInterval(-3 * 86_400 - 5), now: Self.now) == "3d ago")
    }
}

/// The field on the wire and in the table.
@Suite struct ThreadActivityListingTests {
    @Test func theActivityIsOptionalOnTheWireAndLastInTheTable() throws {
        let thread = ThreadSummary(id: "aaaaaaaaaaa1", title: "fix", driver: "claude-code", scope: "acme",
                                   scopeSlug: "acme", task: nil, cwd: "/w", state: "running", alive: true,
                                   openedBy: "user", depth: 0, activity: "Edit a.swift · 2m ago")
        let decoded = try JSONDecoder().decode(ListResult.self, from: JSONEncoder().encode(ListResult(threads: [thread])))
        #expect(decoded.threads.first?.activity == "Edit a.swift · 2m ago")
        // A list from a build before the field still decodes.
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        older["activity"] = nil
        let old = try JSONDecoder().decode(ThreadSummary.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(old.activity == nil)
        let lines = CLIRenderer.text(.list(ListResult(threads: [thread, old]))).split(separator: "\n")
        #expect(lines.first?.hasSuffix("BY    ACTIVITY") == true)
        #expect(lines.dropFirst().first?.hasSuffix("user  Edit a.swift · 2m ago") == true)
        #expect(lines.last?.hasSuffix("user") == true, "no activity, no trailing blanks")
    }
}
