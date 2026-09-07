import Foundation
import ScopeAdapters
import ScopeCore

/// The `claude-hooks` adapter (spec §4.7): a per-thread Claude Code settings file whose hooks call
/// `scope-hook`, passed to `claude` with `--settings <file>` on every launch and resume.
///
/// Mapping (hook event names and stdin fields verified against code.claude.com/docs/en/hooks; every stdin
/// payload carries `session_id`, lifted by `scope-hook --stdin` into `payload["session_id"]`):
///
/// | Claude Code hook                      | scope-hook event        | thread state          |
/// |---------------------------------------|-------------------------|-----------------------|
/// | `SessionStart`                        | `session.started`       | unchanged (session id)|
/// | `UserPromptSubmit`                    | `turn.started`          | running               |
/// | `PostToolUse`                         | `turn.started`          | running (after a permission was granted) |
/// | `PermissionRequest`                   | `permission.requested`  | waiting(permission)   |
/// | `Notification` (matcher on type)      | `notification` → derived| waiting(permission / input) |
/// | `Stop`                                | `turn.ended`            | done                  |
/// | `SessionEnd`                          | `thread.ended`          | done                  |
///
/// `PreToolUse` is deliberately not used: it fires *before* the permission check, so it could not bring the
/// thread back to `running` once the user approved. `scope-hook` writes nothing on stdout, so no hook ever
/// changes Claude Code's own decisions.
public enum ClaudeHooksAdapter {
    /// `DriverProfile.Adapter.kind` this adapter answers to.
    public static let kind = "claude-hooks"

    /// Seconds Claude Code waits for one hook; `scope-hook` itself gives up on the socket after 2 s.
    public static let hookTimeout = 5

    /// One `"<Event>": [{ matcher?, hooks: [...] }]` entry.
    struct Entry {
        var event: String
        var matcher: String?
        var arguments: [String]
    }

    /// The hooks the settings file declares, in a stable order.
    static let entries: [Entry] = [
        Entry(event: "SessionStart", matcher: nil, arguments: ["session.started", "--stdin"]),
        Entry(event: "UserPromptSubmit", matcher: nil, arguments: ["turn.started", "--stdin"]),
        Entry(event: "PostToolUse", matcher: nil, arguments: ["turn.started", "--stdin"]),
        Entry(event: "PermissionRequest", matcher: nil, arguments: ["permission.requested", "--stdin"]),
        Entry(event: "Notification", matcher: ClaudeNotificationMapping.matcher, arguments: ["notification", "--stdin"]),
        Entry(event: "Stop", matcher: nil, arguments: ["turn.ended", "--stdin"]),
        Entry(event: "SessionEnd", matcher: nil, arguments: ["thread.ended", "--stdin"]),
    ]

    /// `<home>/threads/<thread-id>.claude-settings.json`
    public static func settingsURL(home: URL, threadID: ThreadID) -> URL {
        ScopeHome.threadsURL(home: home).appending(path: "\(threadID.rawValue).claude-settings.json", directoryHint: .notDirectory)
    }

    /// The settings document, as the JSON object Claude Code reads (`{"hooks": {...}}`).
    public static func settings(scopeHookPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for entry in entries {
            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command(scopeHookPath: scopeHookPath, arguments: entry.arguments),
                    "timeout": hookTimeout,
                ] as [String: Any]],
            ]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = [group]
        }
        return ["hooks": hooks]
    }

    /// The settings document serialized (sorted keys, pretty-printed).
    public static func settingsData(scopeHookPath: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings(scopeHookPath: scopeHookPath),
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `'<path>' <event> --stdin` — Claude Code runs hook commands through a shell, so the path is
    /// single-quoted (spaces, `$`, backticks are all inert inside single quotes; an embedded `'` becomes `'\''`).
    public static func command(scopeHookPath: String, arguments: [String]) -> String {
        ([shellQuote(scopeHookPath)] + arguments.map(shellQuote)).joined(separator: " ")
    }

    /// POSIX single-quoting; plain words (`[A-Za-z0-9_./-]+`) are left bare for readability.
    public static func shellQuote(_ word: String) -> String {
        let safe = word.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "." || scalar == "/" || scalar == "-"
        }
        if safe, !word.isEmpty { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes (or rewrites) the settings file for `threadID` and returns the arguments to append to the
    /// `claude` argv: `["--settings", <path>]`. Idempotent; rewriting keeps the file in step with the
    /// current `scope-hook` path after an app update.
    public static func install(home: URL, threadID: ThreadID, scopeHookPath: String) throws(LaunchError) -> [String] {
        let url = settingsURL(home: home, threadID: threadID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settingsData(scopeHookPath: scopeHookPath).write(to: url, options: .atomic)
        } catch {
            throw .adapterSetupFailed("Could not write \(url.path): \(error.localizedDescription)")
        }
        return ["--settings", url.path]
    }

    /// Removes the settings file (when a thread is closed). Missing file is not an error.
    public static func uninstall(home: URL, threadID: ThreadID) {
        try? FileManager.default.removeItem(at: settingsURL(home: home, threadID: threadID))
    }
}

/// Dispatches on `DriverProfile.adapter.kind` before a launch: prepares whatever the adapter needs on disk
/// and returns the extra command-line arguments for `LaunchPlanner.plan(adapterArguments:)`.
///
/// Only `claude-hooks` needs code. `codex-notify` is expressed in the profile itself through the
/// `{scope_hook}` placeholder (`-c notify=[...]`), and `cursor-hooks` is not wired yet.
public enum AdapterInstaller {
    public static func prepare(profile: DriverProfile, threadID: ThreadID, home: URL, scopeHookPath: String) throws(LaunchError) -> [String] {
        switch profile.adapter?.kind {
        case ClaudeHooksAdapter.kind?:
            return try ClaudeHooksAdapter.install(home: home, threadID: threadID, scopeHookPath: scopeHookPath)
        default:
            return []
        }
    }

    /// Cleans up what `prepare` created for `threadID`.
    public static func remove(profile: DriverProfile, threadID: ThreadID, home: URL) {
        if profile.adapter?.kind == ClaudeHooksAdapter.kind {
            ClaudeHooksAdapter.uninstall(home: home, threadID: threadID)
        }
    }
}
