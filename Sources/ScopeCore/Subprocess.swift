import Foundation
import Synchronization

/// Result of a finished subprocess.
public struct ProcessResult: Sendable {
    /// `terminationStatus`: the exit code, or the signal number when `terminationReason == .uncaughtSignal`.
    public let exitCode: Int32
    /// Reason the process ended (`.exit` vs `.uncaughtSignal`), useful to tell a SIGTERM (cancel/timeout) from a real failure.
    public let terminationReason: Process.TerminationReason
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, terminationReason: Process.TerminationReason, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.stdout = stdout
        self.stderr = stderr
    }

    /// `stdout` decoded as UTF-8 (lossy).
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// `stderr` decoded as UTF-8 (lossy).
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// Exited normally with code 0.
    public var succeeded: Bool { exitCode == 0 && terminationReason == .exit }
}

/// Failures of `Subprocess.run`.
public enum SubprocessError: Error, Sendable {
    /// `Process.run()` threw (missing executable, permission denied, bad cwd…).
    case launchFailed(String)
    /// The process was killed because it outlived `timeout`.
    case timedOut(after: Duration)
    /// Reserved for callers that want to throw on a non-zero exit (`Subprocess.run` itself never throws this).
    case nonZeroExit(ProcessResult)
}

/// Thread-safe accumulator used from `readabilityHandler` (which is `@Sendable` and runs on a private queue).
final class DataSink: Sendable {
    private let storage = Mutex(Data())

    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    func take() -> Data {
        storage.withLock { $0 }
    }
}

/// Keeps the `Process` and its `Pipe`s alive until stdout EOF, stderr EOF and termination have all been observed.
///
/// Verified race (macOS 15/26, Swift 6.3): Foundation retains a running `Process` only until it exits.
/// If nothing else references it, the `Process` → `Pipe` → `FileHandle` chain is deallocated right after
/// `terminationHandler` returns, which cancels the readability dispatch sources before they deliver EOF
/// and leaks the continuation. Holding this box from the completion closure removes the hang. The box
/// is only *retained*, never *used*, from other threads, hence `@unchecked Sendable`.
final class ProcessBox: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Breaks the cycle process → terminationHandler → finish → box → process once done.
    func release() {
        process.terminationHandler = nil
    }
}

/// Tracks the pid of a launched process so the (Sendable) cancellation handler can signal it
/// without capturing the `Process` object.
final class ProcessSignaller: Sendable {
    private struct State {
        var pid: pid_t?
        var cancelled = false
    }

    private let state = Mutex(State())

    func didLaunch(pid: pid_t) {
        let shouldKill = state.withLock { s -> Bool in
            s.pid = pid
            return s.cancelled
        }
        if shouldKill {
            kill(pid, SIGTERM)
        }
    }

    func cancel() {
        let pid = state.withLock { s -> pid_t? in
            s.cancelled = true
            return s.pid
        }
        if let pid {
            kill(pid, SIGTERM)
        }
    }

    /// `true` once `cancel()` was called (timeout or task cancellation).
    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }
}

/// Minimal async wrapper around `Foundation.Process`.
///
/// - `executable` is exec'd by absolute path (no PATH search).
/// - `environment` is merged over the current process environment (never replaces it).
/// - `stdin` is written on a background queue; without it the child reads `/dev/null`, so git can
///   never block on a TTY prompt.
/// - Both pipes are drained with `readabilityHandler`s, which avoids the 64 KiB pipe-buffer deadlock
///   when a child writes a lot on stdout and stderr at the same time.
/// - Task cancellation sends SIGTERM and throws `CancellationError`; `timeout` sends SIGTERM and throws
///   `SubprocessError.timedOut`. Once the signalled process has exited, its pipes are closed without
///   waiting for EOF: a grandchild (a `sleep` started by a shell rc file, say) that inherited them
///   must not keep the caller waiting.
public enum Subprocess {
    /// Runs `executable arguments…` to completion and returns its exit status and captured output.
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        guard let timeout else {
            return try await launch(
                executable: executable, arguments: arguments,
                currentDirectory: currentDirectory, environment: environment, stdin: stdin
            )
        }
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await launch(
                    executable: executable, arguments: arguments,
                    currentDirectory: currentDirectory, environment: environment, stdin: stdin
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SubprocessError.timedOut(after: timeout)
            }
            // First child to finish wins; leaving the closure cancels the other one
            // (cancellation of the process child sends SIGTERM via ProcessSignaller).
            guard let result = try await group.next() else {
                throw SubprocessError.launchFailed("subprocess task group produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    private static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        stdin: Data?
    ) async throws -> ProcessResult {
        let signaller = ProcessSignaller()
        let out = DataSink()
        let err = DataSink()

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, any Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let box = ProcessBox(process: process, stdout: stdoutPipe, stderr: stderrPipe)

                let stdinPipe: Pipe?
                if stdin != nil {
                    stdinPipe = Pipe()
                    process.standardInput = stdinPipe
                } else {
                    stdinPipe = nil
                    process.standardInput = FileHandle.nullDevice
                }

                // Three completion events must happen before we resume: stdout EOF, stderr EOF, termination.
                // `force` (termination after SIGTERM) resumes right away: grandchildren may hold the pipes open.
                let pending = Mutex(3)
                let stateBox = Mutex<(status: Int32, reason: Process.TerminationReason)?>(nil)
                let finish: @Sendable (_ force: Bool) -> Void = { force in
                    let done = pending.withLock { count -> Bool in
                        guard count > 0 else { return false }
                        count = force ? 0 : count - 1
                        return count == 0
                    }
                    guard done, let final = stateBox.withLock({ $0 }) else { return }
                    if force {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        try? stdoutPipe.fileHandleForReading.close()
                        try? stderrPipe.fileHandleForReading.close()
                    }
                    box.release()
                    cont.resume(returning: ProcessResult(
                        exitCode: final.status,
                        terminationReason: final.reason,
                        stdout: out.take(),
                        stderr: err.take()
                    ))
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        finish(false)
                    } else {
                        out.append(data)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        finish(false)
                    } else {
                        err.append(data)
                    }
                }
                process.terminationHandler = { proc in
                    stateBox.withLock { $0 = (proc.terminationStatus, proc.terminationReason) }
                    finish(signaller.isCancelled)
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: SubprocessError.launchFailed(error.localizedDescription))
                    return
                }
                signaller.didLaunch(pid: process.processIdentifier)

                if let stdin, let stdinPipe {
                    // Write on a background queue: a big stdin would block otherwise.
                    let writer = stdinPipe.fileHandleForWriting
                    DispatchQueue.global().async {
                        try? writer.write(contentsOf: stdin)
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            signaller.cancel()
        }

        // A cancelled task must not see a "successful" SIGTERM result.
        try Task.checkCancellation()
        return result
    }
}
