import Foundation
import Testing
@testable import ScopeAdapters

@Suite struct ClaudeBackgroundWorkTests {
    typealias F = ClaudeBackgroundFixtures

    /// The work a transcript of `lines` describes, read the way the app reads it.
    static func work(_ lines: [String], into start: ClaudeBackgroundWork = ClaudeBackgroundWork()) -> ClaudeBackgroundWork {
        var tail = ClaudeTranscriptTail()
        var work = start
        for line in lines { work.apply(tail.records(Data(line.utf8))) }
        return work
    }

    static func hook(_ stdin: String, at: Date = Date(timeIntervalSince1970: 1_792_490_000)) -> ClaudeHookFacts {
        ClaudeHookFacts(body: JSONValue(json: stdin)!, at: at)
    }

    static func date(_ text: String) -> Date { TranscriptUsage.parseDate(text)! }

    @Test func anExplicitLaunchRunsUntilItsNotificationSaysExitZero() throws {
        var work = Self.work([F.bashUse, F.bashLaunched])
        let task = try #require(work.task("b00000011"))
        #expect(task.kind == .shell)
        #expect(task.command == "<command one>")
        #expect(task.status == .running)
        #expect(task.startedAt == Self.date("2026-10-20T10:00:01.000Z"))
        #expect(task.movedAfterMs == nil)
        work = Self.work([F.completed], into: work)
        let done = try #require(work.task("b00000011"))
        #expect(done.status == .completed(exitCode: 0))
        #expect(done.outputFile == "/tmp/claude-501/<project>/<session>/tasks/b00000011.output")
        #expect(done.endedAt == Self.date("2026-10-20T10:05:00.000Z"))
        #expect(done.summary?.contains("exit code 0") == true)
    }

    @Test func aCommandMovedToTheBackgroundOnTimeoutStartedWhenItsCallDid() throws {
        let work = Self.work([F.slowUse, F.slowMoved, F.failed])
        let task = try #require(work.task("b00000012"))
        #expect(task.movedAfterMs == 120_000)
        #expect(task.startedAt == Self.date("2026-10-20T10:00:00.000Z"))
        // The quoted command says "exit code 7"; the code is the one at the end.
        #expect(task.status == .failed(exitCode: 2))
    }

    @Test func aDeniedCallStartsNothing() {
        #expect(Self.work([F.deniedUse, F.denied]).tasks.isEmpty)
    }

    @Test func taskStopKillsWithoutANotification() throws {
        let work = Self.work([F.bashUse, F.bashLaunched, F.stopUse, F.stopResult])
        let task = try #require(work.task("b00000011"))
        #expect(task.status == .killed)
        #expect(task.endedAt == Self.date("2026-10-20T10:03:01.000Z"))
    }

    @Test func aKilledNotificationIsKilled() {
        #expect(Self.work([F.bashUse, F.bashLaunched, F.killed]).task("b00000011")?.status == .killed)
    }

    @Test func aSessionEndNoticeStopsEveryTaskItNames() {
        let work = Self.work([F.bashUse, F.bashLaunched, F.slowUse, F.slowMoved, F.stoppedAtSessionEnd])
        #expect(work.task("b00000011")?.status == .stopped)
        #expect(work.task("b00000012")?.status == .stopped)
        #expect(work.running(at: .distantFuture).isEmpty)
    }

    @Test func aMonitorKeepsItsLastEventsAndExpires() throws {
        var work = Self.work([F.monitorUse, F.monitorStarted])
        let started = try #require(work.task("b00000013"))
        #expect(started.kind == .monitor)
        #expect(started.timeoutMs == 120_000)
        #expect(started.expiresAt == Self.date("2026-10-20T10:02:01.000Z"))
        let events = (1...7).map { F.monitorEvent("tick \($0)", at: "2026-10-20T10:00:\(10 + $0).000Z") }
        work = Self.work(events, into: work)
        let watching = try #require(work.task("b00000013"))
        #expect(watching.status == .running)
        #expect(watching.eventCount == 7)
        #expect(watching.events == ["tick 3", "tick 4", "tick 5", "tick 6", "tick 7"])
        // Past its deadline it reads expired before the notice is read, and stays so once it is.
        #expect(watching.status(at: Self.date("2026-10-20T10:03:00.000Z")) == .expired)
        #expect(watching.status(at: Self.date("2026-10-20T10:01:00.000Z")) == .running)
        work = Self.work([F.monitorExpired], into: work)
        #expect(work.task("b00000013")?.status == .expired)
        #expect(work.task("b00000013")?.eventCount == 7)
    }

    @Test func aMonitorWhoseStreamEndedCompleted() throws {
        let work = Self.work([F.monitorUse, F.monitorStarted, F.monitorStreamEnded])
        let task = try #require(work.task("b00000013"))
        #expect(task.status == .completed(exitCode: nil))
        #expect(task.kind == .monitor)
    }

    @Test func aMonitorScriptThatFailedHasItsExitCode() {
        #expect(Self.work([F.monitorUse, F.monitorStarted, F.monitorScriptFailed]).task("b00000013")?.status == .failed(exitCode: 144))
    }

    @Test func aWakeUpIsKeptUntilItFires() throws {
        var work = Self.work([F.wakeupUse, F.wakeupSet])
        let wakeup = try #require(work.wakeup)
        #expect(wakeup.scheduledFor == Date(timeIntervalSince1970: 1_792_490_400))
        #expect(wakeup.reason == "<text>")
        #expect(wakeup.prompt == "<prompt>")
        // A prompt before it is due is somebody else's; the one at its time is the wake-up.
        work.apply(Self.hook(#"{"hook_event_name":"UserPromptSubmit","prompt":"<text>"}"#, at: Date(timeIntervalSince1970: 1_792_490_100)))
        #expect(work.wakeup != nil)
        work.apply(Self.hook(#"{"hook_event_name":"UserPromptSubmit","prompt":"<prompt>"}"#, at: Date(timeIntervalSince1970: 1_792_490_401)))
        #expect(work.wakeup == nil)
    }

    @Test func aStoppedLoopClearsItsWakeUp() {
        let stopped = F.toolResult("toolu_wake2", content: "<text>", result: #"{"stopped":true}"#, at: "2026-10-20T10:01:00.000Z")
        let use = F.toolUse("toolu_wake2", "ScheduleWakeup", input: #"{"delaySeconds":0,"reason":"<text>","prompt":"<prompt>"}"#,
                            at: "2026-10-20T10:00:59.000Z")
        #expect(Self.work([F.wakeupUse, F.wakeupSet, use, stopped]).wakeup == nil)
    }

    @Test func aCronIsCreatedThenDeleted() throws {
        var work = Self.work([F.cronUse, F.cronCreated])
        let cron = try #require(work.crons.first)
        #expect(cron.id == "8840f90e")
        #expect(cron.schedule == "17 3 1 1 *")
        #expect(cron.humanSchedule == "17 3 1 1 *")
        #expect(cron.recurring == false)
        #expect(cron.nextFireAt == Date(timeIntervalSince1970: 1_798_769_820))
        work = Self.work([F.cronDeleteUse, F.cronDeleted], into: work)
        #expect(work.crons.isEmpty)
    }

    @Test func theStopListIsAuthoritative() throws {
        var work = Self.work([F.bashUse, F.bashLaunched, F.slowUse, F.slowMoved])
        let crons = #"[{"id":"c1","schedule":"7 * * * *","recurring":true,"prompt":"<prompt>"}]"#
        // b…12 is still listed, b…11 is gone; a sub-agent and an MCP call are not ours.
        work.apply(Self.hook(F.stop(tasks: #"[{"id":"b00000012","type":"shell","status":"running","description":"<text>","command":"<command two>"},{"id":"a0000000000000001","type":"subagent","status":"running","description":"<text>"},{"id":"k00000001","type":"mcp","status":"running"}]"#,
                                    crons: crons)))
        #expect(work.task("b00000011")?.status == .ended)
        #expect(work.task("b00000012")?.status == .running)
        #expect(work.tasks.count == 2)
        #expect(work.crons.map(\.id) == ["c1"])
        // The notification that comes after says how it ended.
        work = Self.work([F.completed], into: work)
        #expect(work.task("b00000011")?.status == .completed(exitCode: 0))
        // An empty list ends the rest, and the crons with it.
        work.apply(Self.hook(F.stop(tasks: "[]")))
        #expect(work.task("b00000012")?.status == .ended)
        #expect(work.crons.isEmpty)
    }

    @Test func aStopListTheWireCutSaysNothingOfTheRest() {
        var work = Self.work([F.bashUse, F.bashLaunched])
        let others = (0..<20).map { #"{"id":"b1000000\#($0)","type":"shell","status":"running"}"# }.joined(separator: ",")
        work.apply(Self.hook(F.stop(tasks: "[\(others)]")))
        #expect(work.task("b00000011")?.status == .running)
    }

    @Test func aSubAgentStopOrALaunchFromASubAgentIsIgnored() {
        var work = ClaudeBackgroundWork()
        let fromAgent = F.postToolUseBash.replacingOccurrences(of: #""tool_name""#, with: #""agent_id":"a1","tool_name""#)
        work.apply(Self.hook(fromAgent))
        #expect(work.tasks.isEmpty)
        work.apply(Self.hook(F.postToolUseBash))
        #expect(work.task("b00000011")?.status == .running)
        work.apply(Self.hook(#"{"hook_event_name":"SubagentStop","agent_id":"a1","background_tasks":[]}"#))
        #expect(work.task("b00000011")?.status == .running)
    }

    @Test func theHookAndTheTranscriptMakeOneTask() {
        var work = ClaudeBackgroundWork()
        work.apply(Self.hook(F.postToolUseBash))
        work = Self.work([F.bashUse, F.bashLaunched], into: work)
        #expect(work.tasks.count == 1)
        #expect(work.task("b00000011")?.description == "<text>")
    }

    @Test func theEndOfTheSessionStopsWhatStillRuns() {
        var work = Self.work([F.bashUse, F.bashLaunched, F.monitorUse, F.monitorStarted, F.cronUse, F.cronCreated])
        work.apply(Self.hook(F.sessionEnd, at: Self.date("2026-10-20T10:30:00.000Z")))
        #expect(work.task("b00000011")?.status == .stopped)
        // Its deadline had passed: it expired before the session ended.
        #expect(work.task("b00000013")?.status == .expired)
        #expect(work.crons.isEmpty)
        #expect(work.running(at: .distantFuture).isEmpty)
    }

    @Test func aStopFromScopeIsRemembered() {
        var work = Self.work([F.bashUse, F.bashLaunched])
        work.markStopRequested("b00000011")
        #expect(work.task("b00000011")?.stoppedFromScope == true)
    }

    @Test func onlyFinishedTasksAreDropped() {
        var lines: [String] = []
        for index in 0..<30 {
            let id = String(format: "b%08d", 100 + index)
            lines.append(F.toolUse("toolu_\(index)", "Bash", input: #"{"command":"<text>","run_in_background":true}"#, at: "2026-10-20T10:00:00.000Z"))
            lines.append(F.toolResult("toolu_\(index)", content: "<text>", result: #"{"backgroundTaskId":"\#(id)"}"#, at: "2026-10-20T10:00:01.000Z"))
            if index < 25 {
                lines.append(F.notification("<task-id>\(id)</task-id>\n<status>completed</status>\n<summary>Background command \"<text>\" completed (exit code 0)</summary>",
                                            at: "2026-10-20T10:01:00.000Z"))
            }
        }
        let work = Self.work(lines)
        #expect(work.running(at: .distantPast).count == 5)
        #expect(work.tasks.count == 5 + ClaudeBackgroundWork.finishedLimit)
    }

    @Test func exitCodesAreReadFromTheEnd() {
        #expect(ClaudeBackgroundWork.exitCode(in: #"Background command "x" completed (exit code 0)"#) == 0)
        #expect(ClaudeBackgroundWork.exitCode(in: #"Background command "grep" completed (exit code 1: No matches found)"#) == 1)
        #expect(ClaudeBackgroundWork.exitCode(in: #"Background command "echo $? exit code 9" failed with exit code 127"#) == 127)
        #expect(ClaudeBackgroundWork.exitCode(in: #"Monitor "x" script failed (exit 144)"#) == 144)
        #expect(ClaudeBackgroundWork.exitCode(in: #"Background command "x" was stopped"#) == nil)
    }

    @Test func theOutputFileIsDerivedFromTheTranscriptPath() {
        let path = ClaudeBackgroundWork.derivedOutputFile(taskID: "b00000011", transcriptPath: "/Users/u/.claude/projects/-Users-u-repo/1234-abcd.jsonl", uid: 501)
        #expect(path == "/tmp/claude-501/-Users-u-repo/1234-abcd/tasks/b00000011.output")
        #expect(ClaudeBackgroundWork.derivedOutputFile(taskID: "a1", transcriptPath: "/x/p/s.jsonl", uid: 501) == nil)
        #expect(ClaudeBackgroundWork.derivedOutputFile(taskID: "b1/../x", transcriptPath: "/x/p/s.jsonl", uid: 501) == nil)
    }

    @Test func theSessionCarriesIt() {
        var session = ClaudeSession()
        session.apply(Self.hook(F.postToolUseBash))
        #expect(session.background.task("b00000011") != nil)
        var tail = ClaudeTranscriptTail()
        session.apply(tail.records(Data(F.completed.utf8)))
        #expect(session.background.task("b00000011")?.status == .completed(exitCode: 0))
        // A fresh conversation starts with nothing in the background.
        session.apply(Self.hook(#"{"hook_event_name":"SessionStart","source":"clear"}"#))
        #expect(session.background.isEmpty)
    }
}
