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
        #expect(clock.now - start < .seconds(3))
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
        #expect(clock.now - start < .seconds(2))
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
    @Test func burstRunsOnceAfterTheDelay() async throws {
        let gauge = Gauge()
        let debouncer = Debouncer(delay: .milliseconds(80)) { gauge.enter(); gauge.leave() }
        for _ in 0..<5 {
            await debouncer.fire()
            try await Task.sleep(for: .milliseconds(6))
        }
        #expect(gauge.runs == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(gauge.runs == 1)
    }

    @Test func cancelDropsAndFlushRunsNow() async throws {
        let gauge = Gauge()
        let debouncer = Debouncer(delay: .milliseconds(80)) { gauge.enter(); gauge.leave() }

        await debouncer.fire()
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(gauge.runs == 0)

        await debouncer.fire()
        await debouncer.flush()
        #expect(gauge.runs == 1)
        await debouncer.flush()                 // nothing pending
        try await Task.sleep(for: .milliseconds(200))
        #expect(gauge.runs == 1)                // the cancelled timer did not fire a second run
    }

    @Test func throttleRunsLeadingAndOneTrailing() async throws {
        let gauge = Gauge()
        let throttle = Throttle(minimumInterval: .milliseconds(150)) { gauge.enter(); gauge.leave() }
        for _ in 0..<5 {
            await throttle.fire()
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(gauge.runs == 1)                // leading edge
        try await Task.sleep(for: .milliseconds(400))
        #expect(gauge.runs == 2)                // single trailing run
        await throttle.fire()
        try await Task.sleep(for: .milliseconds(40))
        #expect(gauge.runs == 3)                // cooldown over: leading edge again
        await throttle.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(gauge.runs == 3)
    }
}
