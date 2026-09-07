import Foundation

/// Turns a profile `command` into the absolute path `execve` needs.
///
/// SwiftTerm's `startProcess` does no PATH search: a bare `claude` would silently `_exit(127)`. The
/// resolver searches the login-shell PATH instead and lets the caller produce a readable error.
public enum ExecutableResolver {
    /// - `"$SHELL"` → `shell` (when executable).
    /// - Absolute path or `~/…` → returned when it is an executable regular file.
    /// - A relative path containing `/` → resolved against the current directory, same check.
    /// - Bare name → first `PATH` entry containing an executable regular file of that name.
    public static func resolve(_ command: String, path: String, shell: String) -> String? {
        resolve(command, path: path, shell: shell, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Same as `resolve(_:path:shell:)` with an explicit home directory for `~` expansion (tests).
    public static func resolve(_ command: String, path: String, shell: String, homeDirectory: URL) -> String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        if command == "$SHELL" {
            return isExecutableFile(shell) ? shell : nil
        }
        if command == "~" || command.hasPrefix("~/") {
            let relative = String(command.dropFirst(command == "~" ? 1 : 2))
            let expanded = relative.isEmpty ? homeDirectory.path : homeDirectory.appending(path: relative).path
            return isExecutableFile(expanded) ? expanded : nil
        }
        if command.contains("/") {
            let absolute = URL(fileURLWithPath: command).standardizedFileURL.path
            return isExecutableFile(absolute) ? absolute : nil
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: command).path
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// `true` for an executable regular file (directories are "executable" for `access(2)` but not for `execve`).
    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
