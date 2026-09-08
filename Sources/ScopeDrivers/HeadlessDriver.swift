import Foundation
import ScopeCore

/// Runs a driver's headless argv (`claude -p …`, `codex exec …`). Injected so tests never start a real driver.
public protocol HeadlessRunner: Sendable {
    /// `argv[0]` is the command as written in the profile (`claude`), not yet resolved to a path.
    func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult
}

/// The real runner: resolves `argv[0]` on the login-shell PATH and runs it with `Subprocess`.
public struct SubprocessHeadlessRunner: HeadlessRunner {
    /// `PATH` used to resolve the command (the login-shell one, see `ShellEnvironmentResolver`).
    public var path: String
    /// Login shell for `$SHELL` commands.
    public var shell: String
    /// Extra environment merged over the process one.
    public var environment: [String: String]

    public init(path: String, shell: String = ShellEnvironment.loginShell(), environment: [String: String] = [:]) {
        self.path = path
        self.shell = shell
        self.environment = environment
    }

    public func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
        guard let command = argv.first, let executable = ExecutableResolver.resolve(command, path: path, shell: shell) else {
            throw HeadlessError.commandNotFound(argv.first ?? "")
        }
        var env = environment
        env["PATH"] = path
        return try await Subprocess.run(
            executable: executable, arguments: Array(argv.dropFirst()), currentDirectory: cwd,
            environment: env, timeout: timeout
        )
    }
}

/// Failures shared by every headless use of a driver (graph level 1, task proposals).
public enum HeadlessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `argv[0]` is not on PATH.
    case commandNotFound(String)
    /// The driver's JSON envelope reported an error (`{"is_error": true, "result": "…"}`).
    case driverReportedError(String)

    public var description: String {
        switch self {
        case .commandNotFound(let command): "\"\(command)\" not found on PATH"
        case .driverReportedError(let message): "driver failed: \(message)"
        }
    }
}

/// Helpers to get at the JSON object a headless driver was asked for.
public enum HeadlessOutput {
    /// Unwraps a `claude -p --output-format json` envelope (`{"result": "…"}`), strips ```json fences and
    /// the prose around the outermost `{ … }`. Returns the (possibly still invalid) JSON text.
    ///
    /// - Throws: `HeadlessError.driverReportedError` on an `is_error` envelope.
    public static func extractJSONObject(from output: String) throws -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["result"] != nil || object["is_error"] != nil {
            if let isError = object["is_error"] as? Bool, isError {
                throw HeadlessError.driverReportedError((object["result"] as? String) ?? "driver reported an error")
            }
            if let inner = object["result"] as? String {
                text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let inner = object["result"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: inner) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
        text = stripFences(text)
        if !text.hasPrefix("{"), let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            text = String(text[open...close])
        }
        return text
    }

    /// Removes a leading ```json / ``` line and a trailing ``` line.
    public static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
