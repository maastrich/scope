import Foundation
import Testing
@testable import ScopeAdapters
@testable import ScopeControl

@Suite struct BackgroundWorkReportTests {
    typealias F = ClaudeBackgroundFixtures
    static let now = TranscriptUsage.parseDate("2026-10-20T10:12:00.000Z")!

    static func work(_ lines: [String]) -> ClaudeBackgroundWork {
        var tail = ClaudeTranscriptTail()
        var work = ClaudeBackgroundWork()
        for line in lines { work.apply(tail.records(Data(line.utf8))) }
        return work
    }

    @Test func runningFirstThenTheLatestFinishedThenWhatIsScheduled() throws {
        let work = Self.work([F.bashUse, F.bashLaunched, F.slowUse, F.slowMoved, F.completed, F.monitorUse, F.monitorStarted,
                              F.cronUse, F.cronCreated, F.wakeupUse, F.wakeupSet])
        let entries = try #require(BackgroundWorkReport.entries(work, now: Self.now))
        #expect(entries.map(\.id) == ["b00000012", "b00000011", "b00000013", "wakeup", "8840f90e"])
        #expect(entries[0].state == "running")
        #expect(entries[1].state == "completed")
        #expect(entries[1].exitCode == 0)
        // The Monitor's deadline passed at 10:02: it reads expired.
        #expect(entries[2].state == "expired")
        #expect(entries[2].kind == "monitor")
        #expect(entries[4].schedule == "17 3 1 1 *")
    }

    @Test func nothingIsNil() {
        #expect(BackgroundWorkReport.entries(ClaudeBackgroundWork(), now: Self.now) == nil)
        #expect(BackgroundWorkReport.line(nil, now: Self.now) == nil)
    }

    @Test func theLineSaysWhatRunsAndForHowLong() throws {
        let work = Self.work([F.bashUse, F.bashLaunched, F.slowUse, F.slowMoved, F.slowUse, F.completed])
        let entries = BackgroundWorkReport.entries(work, now: Self.now)
        let line = try #require(BackgroundWorkReport.line(entries, now: Self.now))
        #expect(line == "1 running in the background: b00000012 <command two> (shell, 12m)")
    }

    @Test func aFinishedTaskAloneSaysNothing() {
        let entries = BackgroundWorkReport.entries(Self.work([F.bashUse, F.bashLaunched, F.completed]), now: Self.now)
        #expect(entries?.count == 1)
        #expect(BackgroundWorkReport.line(entries, now: Self.now) == nil)
    }

    @Test func finishedTasksAreBounded() {
        var lines: [String] = []
        for index in 0..<8 {
            let id = String(format: "b%08d", 200 + index)
            lines.append(F.toolUse("toolu_\(index)", "Bash", input: #"{"command":"<text>","run_in_background":true}"#, at: "2026-10-20T10:00:00.000Z"))
            lines.append(F.toolResult("toolu_\(index)", content: "<text>", result: #"{"backgroundTaskId":"\#(id)"}"#, at: "2026-10-20T10:00:01.000Z"))
            lines.append(F.notification("<task-id>\(id)</task-id>\n<status>completed</status>\n<summary>Background command \"<text>\" completed (exit code 0)</summary>",
                                        at: "2026-10-20T10:0\(index + 1):00.000Z"))
        }
        let entries = BackgroundWorkReport.entries(Self.work(lines), now: Self.now) ?? []
        #expect(entries.count == BackgroundWorkReport.recentLimit)
        #expect(entries.first?.id == "b00000207")
    }

    @Test func aWaitReportsTheWorkWithoutHoldingOnIt() throws {
        // The wait's own rule is untouched: an idle thread with a shell running is settled.
        let snapshot = ThreadWait.Snapshot(state: "done", agents: 0)
        #expect(ThreadWait.isSettled(snapshot, now: Self.now))
        let entries = BackgroundWorkReport.entries(Self.work([F.bashUse, F.bashLaunched]), now: Self.now)
        let entry = ThreadWaitResult.Entry(thread: "3f9a2c17be04", title: "t", state: "done", settled: true, background: entries)
        let text = CLIRenderer.text(.wait(ThreadWaitResult(threads: [entry], complete: true, waited: 1)))
        #expect(text.contains("1 running in the background: b00000011 <command one> (shell, "))
        #expect(text.contains("not waited on"))
        let decoded = try ControlProtocol.makeDecoder().decode(ThreadWaitResult.Entry.self, from: ControlProtocol.makeEncoder().encode(entry))
        #expect(decoded.background == entries)
    }

    @Test func durations() {
        #expect(BackgroundWorkReport.duration(42) == "42s")
        #expect(BackgroundWorkReport.duration(720) == "12m")
        #expect(BackgroundWorkReport.duration(7500) == "2h05")
        #expect(BackgroundWorkReport.duration(-5) == "0s")
    }
}
