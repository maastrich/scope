import Foundation
import ScopeCore

/// A git command that did not succeed (non-zero exit status or killed by a signal).
///
/// Carries the exact arguments and the full `ProcessResult`, so callers can inspect
/// stderr, and renders a one-line description for logs and `Problem`s.
public struct GitError: Error, Sendable, CustomStringConvertible {
    /// Arguments passed to git, without the executable path.
    public let arguments: [String]
    /// Result of the failed process (exit code, termination reason, stdout, stderr).
    public let result: ProcessResult

    public init(arguments: [String], result: ProcessResult) {
        self.arguments = arguments
        self.result = result
    }

    /// Trimmed stderr — the part users care about ("fatal: not a git repository").
    /// Falls back to the exit status when git printed nothing.
    public var message: String {
        let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if result.terminationReason == .uncaughtSignal { return "killed by signal \(result.exitCode)" }
        return "exit \(result.exitCode)"
    }

    /// The command as the user would type it, for display.
    public var command: String {
        "git " + arguments.joined(separator: " ")
    }

    public var description: String {
        "\(command) failed (\(result.exitCode)): \(message)"
    }
}
