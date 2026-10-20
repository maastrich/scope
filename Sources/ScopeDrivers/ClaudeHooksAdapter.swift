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
/// | `PreToolUse` (question tools only)    | `input.requested`       | waiting(input)        |
/// | `PostToolUse`                         | `turn.started`          | running (after a permission was granted, or a question answered); unchanged once the turn ended (`ThreadActivity.isLate`) |
/// | `Notification` (matcher on type)      | `notification` → derived| waiting(permission / input) |
/// | `Stop`                                | `turn.ended`            | done                  |
/// | `StopFailure`                         | `turn.failed`           | failed                |
/// | `SessionEnd`                          | `thread.ended`          | done                  |
/// | `MessageDisplay`                      | `turn.said`             | unchanged (the answer, as it is written) |
/// | `SubagentStart` / `SubagentStop`      | `agent.started` / `agent.ended` | unchanged (a sub-agent running in the background holds `thread.wait`) |
/// | `PreCompact`, `PostCompact`, `PermissionRequest`, `PermissionDenied`, `PostToolUseFailure`, `PostModelSwitch`, `TaskCreated`, `TaskCompleted` | `driver.reported` | unchanged (`ClaudeSession`; the two task hooks feed the `AgentPlan`) |
///
/// Every event also carries the hook's stdin, clamped, under `payload["hook"]` (`ClaudeHookFacts`).
///
/// The agent's plan is read from the same events: `PostToolUse` of `TodoWrite`, `TaskCreate`, `TaskUpdate`,
/// `TaskList` and `ExitPlanMode` (their input and response are in `raw`), and the `TaskCreated` / `TaskCompleted`
/// hooks, which also fire for a task a teammate creates or completes.
///
/// `MessageDisplay` exists since Claude Code 2.1.152; an older one ignores the entry with a note and keeps the
/// rest of the file, so the reading column simply waits for `Stop` there.
///
/// The same file sets `statusLine` to `scope-hook statusline` when the meter is on: the status line is the one
/// place Claude Code hands out the subscription's `rate_limits` (percentage used and reset of each window), on every
/// assistant message. The hook forwards them as `limits.reported`, then runs the status line the user's own settings
/// name and prints its output, so what shows at the bottom of the terminal does not change (`ClaudeStatusline`).
///
/// `PreToolUse` only listens to the question tools (`ClaudeQuestionTools`): for any other tool it fires *before*
/// the permission check, so it says nothing about whether the user is being asked.
///
/// `PermissionRequest` is deliberately not installed: it fires as the dialog is about to open, alongside every
/// other `PermissionRequest` hook, and any of those may answer on the user's behalf (a companion app, an
/// auto-approver). Nothing follows such an answer until the tool's `PostToolUse`, so a thread running a long
/// command would sit in `waiting` for its whole duration. The `permission_prompt` notification only fires once the
/// dialog has actually waited about six seconds, so it is the one signal that someone has to act. Auto mode's
/// classifier and `bypassPermissions` fire neither. Two moments have no hook at
/// all — an interrupt (Esc) and the approval of a permission prompt — and come from the user's keystrokes instead
/// (`TerminalInputSignal`). `scope-hook` writes nothing on stdout, so no hook ever changes Claude Code's own
/// decisions.
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
        Entry(event: "PreToolUse", matcher: ClaudeQuestionTools.matcher, arguments: ["input.requested", "--stdin"]),
        Entry(event: "PostToolUse", matcher: nil, arguments: ["turn.started", "--stdin"]),
        Entry(event: "Notification", matcher: ClaudeNotificationMapping.matcher, arguments: ["notification", "--stdin"]),
        Entry(event: "Stop", matcher: nil, arguments: ["turn.ended", "--stdin"]),
        Entry(event: "StopFailure", matcher: nil, arguments: ["turn.failed", "--stdin"]),
        Entry(event: "SessionEnd", matcher: nil, arguments: ["thread.ended", "--stdin"]),
        Entry(event: "MessageDisplay", matcher: nil, arguments: ["turn.said", "--stdin"]),
        Entry(event: "SubagentStart", matcher: nil, arguments: ["agent.started", "--stdin"]),
        Entry(event: "SubagentStop", matcher: nil, arguments: ["agent.ended", "--stdin"]),
    ] + informational.map { Entry(event: $0, matcher: nil, arguments: [HookEvent.Kind.driverReported.rawValue, "--stdin"]) }

    /// Hooks that only inform (`driver.reported`): read through `ClaudeHookFacts`, they never move the thread state.
    /// `PermissionRequest` is here as information only — what is being asked, at once — and still not as the signal
    /// that someone must act (see above); `scope-hook` answers nothing, so the dialog opens as it would without it.
    static let informational = ["PreCompact", "PostCompact", "PermissionRequest", "PermissionDenied", "PostToolUseFailure",
                                "PostModelSwitch", "TaskCreated", "TaskCompleted"]

    /// `<home>/threads/<thread-id>.claude-settings.json`
    public static func settingsURL(home: URL, threadID: ThreadID) -> URL {
        ScopeHome.threadsURL(home: home).appending(path: "\(threadID.rawValue).claude-settings.json", directoryHint: .notDirectory)
    }

    /// The settings document, as the JSON object Claude Code reads (`{"hooks": {...}}`), plus `theme` when the
    /// thread wants Claude Code on the terminal's palette: `dark-ansi` / `light-ansi` colour with the 16 ANSI
    /// colours alone, which the app sets to match its appearance. It rides in this file because `--settings`
    /// is given once per launch; a second flag would drop the hooks.
    public static func settings(scopeHookPath: String, theme: TerminalTheme? = nil, statusline: Bool = true) -> [String: Any] {
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
        var document: [String: Any] = ["hooks": hooks]
        if let theme { document["theme"] = "\(theme.rawValue)-ansi" }
        if statusline {
            document["statusLine"] = [
                "type": "command",
                "command": command(scopeHookPath: scopeHookPath, arguments: statuslineArguments),
            ] as [String: Any]
        }
        return document
    }

    /// What the status line runs: `scope-hook statusline --stdin`.
    public static let statuslineArguments = [HookCommandEvent.statuslineWord, "--stdin"]

    /// The settings document serialized (sorted keys, pretty-printed).
    public static func settingsData(scopeHookPath: String, theme: TerminalTheme? = nil, statusline: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings(scopeHookPath: scopeHookPath, theme: theme, statusline: statusline),
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
    public static func install(home: URL, threadID: ThreadID, scopeHookPath: String, theme: TerminalTheme? = nil,
                               statusline: Bool = true) throws(LaunchError) -> [String] {
        let url = settingsURL(home: home, threadID: threadID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settingsData(scopeHookPath: scopeHookPath, theme: theme, statusline: statusline).write(to: url, options: .atomic)
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
    /// `theme` is the terminal palette Claude Code should draw with, `nil` to leave its own theme alone; `statusline`
    /// whether the limits meter is on, which is what installs the status-line relay.
    public static func prepare(profile: DriverProfile, threadID: ThreadID, home: URL, scopeHookPath: String,
                               theme: TerminalTheme? = nil, statusline: Bool = true) throws(LaunchError) -> [String] {
        switch profile.adapter?.kind {
        case ClaudeHooksAdapter.kind?:
            return try ClaudeHooksAdapter.install(home: home, threadID: threadID, scopeHookPath: scopeHookPath, theme: theme,
                                                  statusline: statusline)
        default:
            return []
        }
    }

    /// `true` when the profile's adapter reports turns at all. `cursor-hooks` is declared but not wired yet, so a
    /// Cursor thread knows nothing beyond "alive".
    public static func deliversEvents(_ profile: DriverProfile) -> Bool {
        switch profile.adapter?.kind {
        case ClaudeHooksAdapter.kind?, "codex-notify"?: true
        default: false
        }
    }

    /// `true` when the adapter reports the start of a turn itself. Without it (Codex `notify`), the user
    /// submitting a prompt is the only sign a turn has started (see `ThreadStateMachine.next(_:onUserInput:…)`).
    public static func reportsTurnStart(_ profile: DriverProfile) -> Bool {
        profile.adapter?.kind == ClaudeHooksAdapter.kind
    }

    /// Cleans up what `prepare` created for `threadID`.
    public static func remove(profile: DriverProfile, threadID: ThreadID, home: URL) {
        if profile.adapter?.kind == ClaudeHooksAdapter.kind {
            ClaudeHooksAdapter.uninstall(home: home, threadID: threadID)
        }
    }
}
