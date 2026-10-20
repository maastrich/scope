import Foundation

/// The status line Scope's per-thread settings file replaces, and how `scope-hook statusline` gives it back.
///
/// Claude Code takes `statusLine` from the highest-ranking settings source that sets it, and the `--settings` file
/// Scope passes ranks above the user's and a project's. So, having read `rate_limits`, the hook runs the command those
/// files would have run — the project's local settings first, then the project's, then the user's, in Claude Code's
/// own order — on the same stdin, and prints what it prints. Managed (enterprise) settings rank above `--settings`
/// and are not touched: when they set a status line, Scope's never runs. Nothing in `~/.claude` is modified.
public enum ClaudeStatusline {
    /// Set in the user's command's environment; a `scope-hook statusline` finding it set runs no command of its own,
    /// so a status line that somehow calls back into the hook ends there.
    public static let nestedVariable = "SCOPE_STATUSLINE_NESTED"

    /// A `statusLine` of `type: command`, as the settings have it.
    public struct Command: Sendable, Equatable {
        public var command: String
        /// `padding` as Claude Code reads it; passed back through its own output, so only kept for the record.
        public var padding: Int?

        public init(command: String, padding: Int? = nil) {
            self.command = command
            self.padding = padding
        }
    }

    /// The settings files that could have set a status line, highest-ranking first, for a session working in
    /// `projectDirectory` under a user whose Claude Code configuration is `configDirectory`
    /// (`$CLAUDE_CONFIG_DIR`, else `~/.claude`).
    public static func settingsFiles(projectDirectory: String?, configDirectory: URL) -> [URL] {
        var files: [URL] = []
        if let project = projectDirectory, project.hasPrefix("/") {
            let claude = URL(fileURLWithPath: project, isDirectory: true).appending(path: ".claude", directoryHint: .isDirectory)
            files.append(claude.appending(path: "settings.local.json", directoryHint: .notDirectory))
            files.append(claude.appending(path: "settings.json", directoryHint: .notDirectory))
        }
        files.append(configDirectory.appending(path: "settings.json", directoryHint: .notDirectory))
        return files
    }

    public static func configDirectory(environment: [String: String],
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return home.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// The `statusLine` command in one settings document, `nil` when it sets none of `type: command`.
    public static func command(in data: Data) -> Command? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statusLine = object["statusLine"] as? [String: Any],
              (statusLine["type"] as? String ?? "command") == "command",
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Command(command: command, padding: (statusLine["padding"] as? NSNumber)?.intValue)
    }

    /// The command of the first file (in rank order) that sets one; a file missing or unreadable is skipped.
    public static func userCommand(files: [URL], read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Command? {
        for file in files {
            if let data = read(file), let command = command(in: data) { return command }
        }
        return nil
    }

    /// Whether this run of the hook is itself the user's status line being run by another: then it is a plain
    /// status line and runs nothing further.
    public static func isNested(environment: [String: String]) -> Bool {
        environment[nestedVariable].map { !$0.isEmpty } ?? false
    }
}
