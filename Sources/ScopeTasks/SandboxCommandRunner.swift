import Foundation
import ScopeCore

/// What a setup or teardown command did.
public struct CommandOutcome: Sendable, Equatable {
    /// `nil` when the command never ran (launch failure) or was killed by the timeout.
    public var exitCode: Int32?
    public var timedOut: Bool
    /// stdout and stderr, in that order.
    public var output: String

    public init(exitCode: Int32?, timedOut: Bool = false, output: String = "") {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.output = output
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// `exit 1`, `timed out after 600 s`, `could not start`.
    public var summary: String {
        if timedOut { return "timed out" }
        guard let exitCode else { return "could not start" }
        return "exit \(exitCode)"
    }
}

/// Runs one shell command in a sandbox. Injected into `TaskManager` so the setup and teardown paths are testable
/// with a double, and so the app decides which shell and which environment the commands see.
public protocol SandboxCommandRunner: Sendable {
    func run(_ command: String, in directory: URL, environment: [String: String], timeout: Duration) async -> CommandOutcome
}

/// The real runner: `<shell> -c <command>` with the login-shell environment the app resolved once, plus the
/// task's variables. `-c` rather than `-lc`: the environment already went through the rc files, and running them
/// again for every command costs seconds and prints their noise into the log.
public struct ShellCommandRunner: SandboxCommandRunner {
    public var shell: String
    public var baseEnvironment: [String: String]

    public init(shell: String, baseEnvironment: [String: String]) {
        self.shell = shell
        self.baseEnvironment = baseEnvironment
    }

    public func run(_ command: String, in directory: URL, environment: [String: String], timeout: Duration) async -> CommandOutcome {
        do {
            let result = try await Subprocess.run(
                executable: shell, arguments: ["-c", command], currentDirectory: directory,
                environment: baseEnvironment.merging(environment) { $1 }.merging(["TERM": "dumb"]) { $1 },
                timeout: timeout
            )
            let output = [result.stdoutText, result.stderrText].filter { !$0.isEmpty }.joined(separator: "\n")
            return CommandOutcome(exitCode: result.exitCode, output: output)
        } catch SubprocessError.timedOut {
            return CommandOutcome(exitCode: nil, timedOut: true)
        } catch {
            return CommandOutcome(exitCode: nil, output: String(describing: error))
        }
    }
}
