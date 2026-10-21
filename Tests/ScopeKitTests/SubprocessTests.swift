import Foundation
import Synchronization
import Testing
@testable import ScopeCore

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "scope-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SubprocessTests {
    @Test func drainsBothPipesWithoutDeadlock() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' a & head -c 300000 /dev/zero | tr '\\0' b >&2; wait"
        let result = try await Subprocess.run(executable: "/bin/sh", arguments: ["-c", script], timeout: .seconds(20))
        #expect(result.succeeded)
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "b") })
    }

    @Test func anExplicitBaseReplacesTheInheritedEnvironment() async throws {
        // The shell probe starts from the app's own variables, never from the widened base everything else gets.
        let result = try await Subprocess.run(executable: "/usr/bin/env", arguments: [], environment: ["B": "2"],
                                              base: ["A": "1"], timeout: .seconds(10))
        let lines = Set(result.stdoutText.split(separator: "\n").map(String.init))
        #expect(lines == ["A=1", "B=2"])
    }

    @Test func stdinIsDelivered() async throws {
        let payload = Data(String(repeating: "hello\n", count: 20_000).utf8)   // > 64 KiB
        let result = try await Subprocess.run(executable: "/bin/cat", arguments: [], stdin: payload, timeout: .seconds(20))
        #expect(result.succeeded)
        #expect(result.stdout == payload)
    }

    @Test func nonZeroExitIsReportedNotThrown() async throws {
        let result = try await Subprocess.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.terminationReason == .exit)
        #expect(!result.succeeded)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
    }

    @Test func timeoutKillsTheChild() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SubprocessError.self) {
            try await Subprocess.run(executable: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(300))
        }
        // The child would run for 10 s; anything well under that proves the kill.
        // Loose bound: CI runners are slow and run suites in parallel.
        #expect(clock.now - start < .seconds(8))
    }

    @Test func cancellationKillsTheChild() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await Subprocess.run(executable: "/bin/sleep", arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.now - start < .seconds(8))
    }

    @Test func currentDirectoryAndEnvironmentMerge() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pwd = try await Subprocess.run(executable: "/bin/pwd", arguments: [], currentDirectory: dir)
        let reported = pwd.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        // /var/... vs /private/var/...: compare realpaths, never strings.
        #expect(URL(fileURLWithPath: reported).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)

        let env = try await Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "printf '%s|%s' \"$PROBE_X\" \"$HOME\""],
            environment: ["PROBE_X": "1"]
        )
        let parts = env.stdoutText.split(separator: "|", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(parts.first == "1")
        #expect(parts.last?.isEmpty == false)   // inherited, not replaced
    }

    @Test func launchFailureIsAnError() async {
        await #expect(throws: SubprocessError.self) {
            try await Subprocess.run(executable: "/nonexistent/bin/tool", arguments: [])
        }
    }
}

private final class Gauge: Sendable {
    private let state = Mutex((current: 0, peak: 0, runs: 0))

    func enter() {
        state.withLock {
            $0.current += 1
            $0.runs += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func leave() {
        state.withLock { $0.current -= 1 }
    }

    var peak: Int { state.withLock { $0.peak } }
    var runs: Int { state.withLock { $0.runs } }
}

private struct Boom: Error {}

@Suite struct AsyncSemaphoreSmoke {
    @Test func neverExceedsTheLimit() async {
        let semaphore = AsyncSemaphore(limit: 2)
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await semaphore.withPermit {
                        gauge.enter()
                        try? await Task.sleep(for: .milliseconds(15))
                        gauge.leave()
                    }
                }
            }
        }
        #expect(gauge.runs == 12)
        #expect(gauge.peak == 2)
    }

    @Test func withPermitRethrowsAndReleases() async {
        let semaphore = AsyncSemaphore(limit: 1)
        await #expect(throws: Boom.self) {
            try await semaphore.withPermit { throw Boom() }
        }
        // The permit came back: this would hang otherwise.
        let value = await semaphore.withPermit { 42 }
        #expect(value == 42)
    }
}

@Suite struct DebouncerSmoke {
    // Both actors sleep on a `TestClock`: the burst below is "within the delay" by construction, not because the
    // runner happened to schedule five fires inside 80 real milliseconds.

    @Test func burstRunsOnceAfterTheDelay() async throws {
        let gauge = Gauge()
        let clock = TestClock()
        let debouncer = Debouncer(delay: .milliseconds(80), clock: clock) { gauge.enter(); gauge.leave() }
        for _ in 0..<5 {
            await debouncer.fire()
            clock.advance(by: .milliseconds(10))                  // five fires spread over 40 ms, each re-arming
        }
        #expect(await eventually { clock.sleeping == 1 })
        #expect(gauge.runs == 0)
        clock.advance(by: .milliseconds(70))                      // 70 ms after the last fire: not yet
        #expect(gauge.runs == 0)
        clock.advance(by: .milliseconds(10))                      // 80 ms: once
        #expect(await eventually { gauge.runs == 1 })
        #expect(clock.sleeping == 0)
    }

    @Test func cancelDropsAndFlushRunsNow() async throws {
        let gauge = Gauge()
        let clock = TestClock()
        let debouncer = Debouncer(delay: .milliseconds(80), clock: clock) { gauge.enter(); gauge.leave() }

        await debouncer.fire()
        await debouncer.cancel()
        clock.advance(by: .seconds(1))
        #expect(await eventually { clock.sleeping == 0 })
        #expect(gauge.runs == 0)

        await debouncer.fire()
        await debouncer.flush()
        #expect(gauge.runs == 1)
        await debouncer.flush()                 // nothing pending
        clock.advance(by: .seconds(1))
        #expect(await eventually { clock.sleeping == 0 })
        #expect(gauge.runs == 1)                // the cancelled timer did not fire a second run
    }

    @Test func throttleRunsLeadingAndOneTrailing() async throws {
        let gauge = Gauge()
        let clock = TestClock()
        let throttle = Throttle(minimumInterval: .milliseconds(150), clock: clock) { gauge.enter(); gauge.leave() }
        for _ in 0..<5 {
            await throttle.fire()
        }
        #expect(await eventually { gauge.runs >= 1 })
        #expect(gauge.runs == 1)                // leading edge, the other four coalesce
        #expect(await eventually { clock.sleeping == 1 })
        clock.advance(by: .milliseconds(150))   // cooldown over: the one trailing run
        #expect(await eventually { gauge.runs >= 2 })
        #expect(await eventually { clock.sleeping == 1 })   // its own cooldown
        clock.advance(by: .milliseconds(150))
        #expect(await eventually { clock.sleeping == 0 })
        #expect(gauge.runs == 2)                // exactly one trailing run, then quiet
        await throttle.fire()
        #expect(await eventually { gauge.runs >= 3 })
        #expect(gauge.runs == 3)                // leading edge again
        await throttle.cancel()
        clock.advance(by: .seconds(1))
        #expect(await eventually { clock.sleeping == 0 })
        #expect(gauge.runs == 3)
    }
}

/// When a launched process's continuation resumes. A lost resume is a git command that never returns — and every
/// later command on that repository queued behind it for the life of the app.
@Suite struct SubprocessCompletionTests {
    typealias C = SubprocessCompletion
    static let exited = C.Event.terminated(status: 0, reason: .exit)

    /// Feeds `events` in order: each "resume now?" answer, and the state left at the end.
    static func feed(_ events: [C.Event]) -> (answers: [Bool], state: C) {
        var completion = C()
        let answers = events.map { completion.record($0) }
        return (answers, completion)
    }

    @Test func theNormalOrderResumesOnce() {
        let run = Self.feed([.stdoutClosed, .stderrClosed, Self.exited, Self.exited, .cancelled])
        #expect(run.answers == [false, false, true, false, false])
    }

    /// The bug: a pipe reporting its end twice used to finish the count before the process had terminated.
    @Test func aPipeClosingTwiceDoesNotFinishTheRunAlone() {
        let run = Self.feed([.stdoutClosed, .stdoutClosed, .stderrClosed, Self.exited])
        #expect(run.answers == [false, false, false, true], "termination must still resume once it arrives")
    }

    @Test func terminationFirstWaitsForBothPipes() {
        let run = Self.feed([Self.exited, .stderrClosed, .stdoutClosed])
        #expect(run.answers == [false, false, true])
        #expect(run.state.status == 0)
    }

    /// A grandchild can keep the pipes open after the process exited; a cancellation must not wait for them.
    @Test func cancellingAfterTheProcessExitedResumesWithPipesOpen() {
        let run = Self.feed([Self.exited, .cancelled])
        #expect(run.answers == [false, true])
        #expect(!run.state.pipesClosed)
    }

    @Test func cancellingBeforeTheProcessExitedResumesWhenItDoes() {
        let run = Self.feed([.cancelled, .stdoutClosed, .terminated(status: 15, reason: .uncaughtSignal)])
        #expect(run.answers == [false, false, true])
        #expect(run.state.reason == .uncaughtSignal)
    }

    @Test func theFirstTerminationStatusWins() {
        let run = Self.feed([.terminated(status: 3, reason: .exit), .terminated(status: 0, reason: .exit)])
        #expect(run.state.status == 3)
    }
}
