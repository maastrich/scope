import Foundation
import Testing
@testable import ScopeCore

/// The test process stands for the thread: what it spawns, wrapped the way Claude Code wraps a background command,
/// stands for the task.
@Suite(.serialized) struct BackgroundProcessTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scope-bg-\(UUID().uuidString)/tasks")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `sh -c '… eval '<command>' …'`, its output to `output` when given.
    private func spawn(_ command: String, output: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = command.replacingOccurrences(of: "'", with: #"'\''"#)
        process.arguments = ["-c", "true && eval '\(quoted)' < /dev/null && true"]
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        try process.run()
        return process
    }

    @Test func findsTheShellWritingTheOutputFileAndStopsItsTree() async throws {
        let output = try folder().appending(path: "b00000011.output")
        let task = try spawn("sleep 61", output: output)
        let other = try spawn("sleep 61", output: output.deletingLastPathComponent().appending(path: "b00000012.output"))
        defer { other.terminate() }
        try await Task.sleep(for: .milliseconds(300))

        let target = try #require(BackgroundProcess.find(under: getpid(), outputFile: output.path, command: nil))
        #expect(target.pid == task.processIdentifier)
        // `Process` gives the shell a group of its own, as Claude Code does; never the test's group.
        #expect(target.group == task.processIdentifier)
        #expect(target.group != getpgrp())
        #expect(target.tree.count >= 2)
        #expect(await BackgroundProcess.stop(target, grace: .milliseconds(500)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!task.isRunning)
        #expect(other.isRunning)
    }

    @Test func findsAMonitorByItsCommandAndRefusesAnAmbiguousOne() async throws {
        let command = "echo 'tick' && sleep 63"
        let monitor = try spawn(command)
        defer { monitor.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        let target = try #require(BackgroundProcess.find(under: getpid(), outputFile: "/nonexistent/tasks/b1.output", command: command))
        #expect(target.pid == monitor.processIdentifier)

        let twin = try spawn(command)
        defer { twin.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(BackgroundProcess.find(under: getpid(), outputFile: nil, command: command) == nil)
    }

    @Test func nothingOutsideTheRootIsFound() throws {
        // launchd has no descendants of ours; a pid of 1 or less is refused outright.
        #expect(BackgroundProcess.find(under: 1, outputFile: nil, command: "sleep 61") == nil)
        #expect(BackgroundProcess.find(under: getpid(), outputFile: nil, command: "a command nothing runs") == nil)
    }

    @Test func evalMatchesClaudeCodesQuoting() {
        let argv = ["/bin/zsh", "-c", #"source x 2>/dev/null || true && eval 'echo '\''hi'\'' | grep h' < /dev/null && pwd -P >| /tmp/c"#]
        #expect(BackgroundProcess.evals(argv, command: "echo 'hi' | grep h"))
        #expect(!BackgroundProcess.evals(argv, command: "echo 'hi'"))
    }
}
