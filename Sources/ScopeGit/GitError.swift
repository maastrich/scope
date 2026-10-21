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

    /// A plain-words reading of a failure whose cause is not in git itself (see `GitFailureHint`), or `nil`.
    public var hint: String? { GitFailureHint.explain(message) }

    public var description: String {
        let text = "\(command) failed (\(result.exitCode)): \(message)"
        guard let hint else { return text }
        return "\(hint)\n\n\(text)"
    }
}

/// Failures git reports in its own words but whose cause is a missing tool.
///
/// A repository with Git LFS runs `git-lfs` from its filters and hooks; when git cannot start it, every checkout,
/// `worktree add` included, dies with `git-lfs: command not found` and a `remote end hung up` that points nowhere.
public enum GitFailureHint {
    /// The sentences git and the LFS hooks print when `git-lfs` is not on `PATH`.
    static let lfsMissingMarkers = [
        "git-lfs: command not found",
        "'git-lfs' was not found on your path",
        "git-lfs: not found",
    ]

    /// `true` when `message` says git could not run `git-lfs`.
    public static func isLFSMissing(_ message: String) -> Bool {
        lfsMissingMarkers.contains { message.contains($0) }
    }

    /// Folders `git-lfs` is commonly installed in besides Scope's `PATH`: Homebrew, MacPorts, Nix, `~/.local`.
    static func installFolders(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.nix-profile/bin", "/run/current-system/sw/bin",
         "\(home)/.local/bin", "\(home)/bin"]
    }

    /// What to tell the user, or `nil` when `message` is not one of these failures.
    ///
    /// - Parameters:
    ///   - path: the `PATH` Scope's git ran with.
    ///   - isExecutable: injected for tests.
    public static func explain(
        _ message: String,
        path: String = SubprocessEnvironment.current["PATH"] ?? "",
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard isLFSMissing(message) else { return nil }
        let onPath = path.split(separator: ":").map(String.init)
        if let found = onPath.map({ "\($0)/git-lfs" }).first(where: isExecutable) {
            return "git-lfs is on Scope's PATH (\(found)) but git could not start it. Check that `\(found) version` "
                + "runs in a terminal."
        }
        if let found = installFolders(home: home).map({ "\($0)/git-lfs" }).first(where: isExecutable) {
            let folder = (found as NSString).deletingLastPathComponent
            return "git-lfs is installed (\(found)) but not on Scope's PATH. Add \(folder) to the PATH your login "
                + "shell exports, then Re-probe Shell in Settings and try again."
        }
        return "git-lfs is not installed, and this repository needs it (its git config runs git-lfs as a filter). "
            + "Install it (brew install git-lfs), then try again."
    }
}
