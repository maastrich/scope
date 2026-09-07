import Darwin
import Foundation
import ScopeCore

/// The user's login shell and the environment it builds.
///
/// A GUI app launched from Finder / Dock inherits launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which never contains `claude`, `codex`, Homebrew or `~/.cargo/bin`. The fix (VS Code's "shell environment
/// resolution") is to run the login shell once and read the environment it ends up with.
public enum ShellEnvironment {
    /// The account's login shell from the passwd database, falling back to `$SHELL`, then `/bin/zsh`.
    ///
    /// passwd beats `$SHELL` because the app's environment comes from launchd, not from a shell.
    public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = passwdShell(), !shell.isEmpty { return shell }
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// Runs `<shell> -ilc` (or `-lc`) with `TERM=dumb`, `SCOPE_ENV_PROBE=1` and prints `/usr/bin/env -0` between
    /// two random markers. Returns the variables between the markers, or nil on timeout, non-zero exit or missing
    /// markers. `.none` never runs the shell and returns nil.
    public static func probe(
        shell: String,
        mode: ShellProbeMode,
        timeout: Duration = .seconds(10)
    ) async -> [String: String]? {
        if case .success(let variables) = await probeOutcome(shell: shell, mode: mode, timeout: timeout) {
            return variables
        }
        return nil
    }

    /// The `PATH` assembled by `/usr/libexec/path_helper -s` from `/etc/paths` and `/etc/paths.d`
    /// (no user additions: no Homebrew, no `~/.cargo/bin`). Used as a fallback when the shell probe fails.
    public static func pathHelperPATH() async -> String? {
        guard let result = try? await Subprocess.run(
            executable: "/usr/libexec/path_helper",
            arguments: ["-s"],
            timeout: .seconds(5)
        ), result.succeeded else { return nil }
        // Output: PATH="/usr/local/bin:/usr/bin:..."; export PATH;
        let text = result.stdoutText
        guard let start = text.range(of: "PATH=\""),
              let end = text[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let path = String(text[start.upperBound..<end])
        return path.isEmpty ? nil : path
    }

    // MARK: - Internals shared with ShellEnvironmentResolver

    /// Detailed probe result, so the resolver can explain *why* it fell back.
    enum ProbeOutcome: Sendable, Equatable {
        case success([String: String])
        case timedOut(Duration)
        case launchFailed(String)
        case exited(Int32)
        case missingMarkers
        case skipped
    }

    /// Flags for `mode`: `-ilc` reads `.zshrc` / `config.fish` where most people export PATH; `-lc` only reads
    /// the profile files. nil for `.none`.
    static func shellFlags(for mode: ShellProbeMode) -> String? {
        switch mode {
        case .interactiveLogin: return "-ilc"
        case .login: return "-lc"
        case .none: return nil
        }
    }

    static func probeOutcome(shell: String, mode: ShellProbeMode, timeout: Duration) async -> ProbeOutcome {
        guard let flags = shellFlags(for: mode) else { return .skipped }
        let marker = "__SCOPE_ENV_\(UUID().uuidString)__"
        let script = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"
        let result: ProcessResult
        do {
            result = try await Subprocess.run(
                executable: shell,
                arguments: [flags, script],
                environment: ["TERM": "dumb", "SCOPE_ENV_PROBE": "1"],
                timeout: timeout
            )
        } catch SubprocessError.timedOut(let after) {
            return .timedOut(after)
        } catch SubprocessError.launchFailed(let message) {
            return .launchFailed(message)
        } catch SubprocessError.nonZeroExit(let failed) {
            return .exited(failed.exitCode)
        } catch {
            return .launchFailed(String(describing: error))
        }
        guard result.succeeded else { return .exited(result.exitCode) }
        guard let variables = parse(markedOutput: result.stdoutText, marker: marker) else { return .missingMarkers }
        return .success(variables)
    }

    /// Extracts the `KEY=VALUE\0` records between the first and the last occurrence of `marker`.
    static func parse(markedOutput text: String, marker: String) -> [String: String]? {
        guard let first = text.range(of: marker),
              let last = text.range(of: marker, options: .backwards),
              first.upperBound <= last.lowerBound
        else { return nil }
        var variables: [String: String] = [:]
        for record in text[first.upperBound..<last.lowerBound].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = record.firstIndex(of: "=") else { continue }
            let key = String(record[..<equals])
            guard !key.isEmpty else { continue }
            variables[key] = String(record[record.index(after: equals)...])
        }
        return variables
    }

    /// `getpwuid_r` (reentrant) → `pw_shell`.
    private static func passwdShell() -> String? {
        let size = sysconf(_SC_GETPW_R_SIZE_MAX)
        let capacity = size > 0 ? Int(size) : 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>? = nil
        guard getpwuid_r(getuid(), &entry, buffer, capacity, &found) == 0, found != nil, let shell = entry.pw_shell else {
            return nil
        }
        return String(cString: shell)
    }
}
