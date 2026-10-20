import Foundation

/// The ground a thread's terminal is drawn on when it launches. Tools that adapt to their terminal read it two
/// ways: `COLORFGBG` (the convention iTerm2 and Konsole set; Claude Code's `theme: auto` falls back to it)
/// and the `{theme}` placeholder in a driver profile's argv.
public enum TerminalTheme: String, Sendable, Equatable, CaseIterable {
    case dark, light

    /// `COLORFGBG`: `<foreground>;<background>` as ANSI indexes — `15;0` white on black, `0;15` black on white.
    public var colorFGBG: String {
        switch self {
        case .dark: "15;0"
        case .light: "0;15"
        }
    }
}

/// Builds the complete environment of a PTY child.
///
/// SwiftTerm's `startProcess(environment:)` *replaces* the environment (raw `execve` envp), so every
/// variable the child needs has to be here: the resolved login-shell environment, the terminal variables,
/// the `SCOPE_*` variables and the driver profile's `env`.
public enum TerminalEnvironment {
    /// The variables Scope injects into every thread so hooks and tools can find their way back.
    public struct ScopeVariables: Sendable, Equatable {
        /// `SCOPE_THREAD` — the thread id; nil for a task's shell pane, which is no thread (`TaskShell`).
        public var thread: String?
        /// `SCOPE_SCOPE` — the scope slug.
        public var scope: String
        /// `SCOPE_SCOPE_ROOT` — the scope root path.
        public var scopeRoot: String
        /// `SCOPE_TASK` — the task root path (M2); omitted when nil.
        public var task: String?
        /// `SCOPE_SOCK` — the hook socket path.
        public var sock: String
        /// `SCOPE_HOME`
        public var home: String

        public init(thread: String?, scope: String, scopeRoot: String, task: String? = nil, sock: String, home: String) {
            self.thread = thread
            self.scope = scope
            self.scopeRoot = scopeRoot
            self.task = task
            self.sock = sock
            self.home = home
        }

        /// `SCOPE_THREAD` (omitted if nil), `SCOPE_SCOPE`, `SCOPE_SCOPE_ROOT`, `SCOPE_TASK` (omitted if nil), `SCOPE_SOCK`,
        /// `SCOPE_HOME`.
        public var asDictionary: [String: String] {
            var variables = [
                "SCOPE_SCOPE": scope,
                "SCOPE_SCOPE_ROOT": scopeRoot,
                "SCOPE_SOCK": sock,
                "SCOPE_HOME": home,
            ]
            if let thread { variables["SCOPE_THREAD"] = thread }
            if let task { variables["SCOPE_TASK"] = task }
            return variables
        }
    }

    /// Variables that describe the *app's* process, not the child's, and must not leak into it.
    public static let strippedKeys: Set<String> = [
        "OLDPWD", "SHLVL", "_", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "SCOPE_ENV_PROBE",
    ]

    /// Everything Scope puts into a thread or a setup script. A thread only ever gets these from the app that
    /// opens it: an app started from another Scope's thread (a Debug build run from an agent, Xcode opened from
    /// a Scope terminal) carries that thread's copies, and a thread with no task would otherwise keep the other
    /// app's `SCOPE_TASK`, `SCOPE_TASK_ROOT` and `SCOPE_PORT`, since nothing overwrites what it does not set.
    public static let injectedKeys: Set<String> = [
        "SCOPE_HOME", "SCOPE_SOCK", "SCOPE_PORT", "SCOPE_THREAD", "SCOPE_TASK", "SCOPE_TASK_ROOT", "SCOPE_SCOPE",
        "SCOPE_SCOPE_ROOT", "SCOPE_SANDBOX", "SCOPE_BASE_PATH", "SCOPE_DEFAULT_BRANCH",
    ]

    /// `TERM` value for every thread.
    public static let term = "xterm-256color"

    /// `base` → + `TERM`, `COLORTERM`, `COLORFGBG` (from `theme`), `LANG` (kept if UTF-8, else `en_US.UTF-8`),
    /// `TERM_PROGRAM=Scope`, `TERM_PROGRAM_VERSION`, `SHELL`, `PWD=cwd` → − `strippedKeys`, `injectedKeys` → + `helpers` on
    /// `PATH` → + scope variables → + `driverEnv` (already expanded by the caller).
    ///
    /// `helpers` is the app's `Contents/Helpers`: putting it first on `PATH` is what makes `scope` and
    /// `scope-hook` work inside a thread with nothing to install and nothing to configure.
    public static func build(
        base: [String: String],
        shell: String,
        cwd: String,
        scope: ScopeVariables,
        driverEnv: [String: String],
        appVersion: String,
        helpers: String? = nil,
        theme: TerminalTheme = .dark
    ) -> [String: String] {
        var environment = base
        environment["TERM"] = term
        environment["COLORTERM"] = "truecolor"
        environment["COLORFGBG"] = theme.colorFGBG
        environment["LANG"] = utf8Locale(environment["LANG"])
        environment["TERM_PROGRAM"] = "Scope"
        environment["TERM_PROGRAM_VERSION"] = appVersion
        environment["SHELL"] = shell
        environment["PWD"] = cwd
        for key in strippedKeys.union(injectedKeys) { environment.removeValue(forKey: key) }
        if let helpers, !helpers.isEmpty {
            environment["PATH"] = prepend(helpers, to: environment["PATH"] ?? "")
        }
        for (key, value) in scope.asDictionary { environment[key] = value }
        for (key, value) in driverEnv { environment[key] = value }
        return environment
    }

    /// `"KEY=VALUE"` entries sorted by key, deterministic for tests and logs.
    public static func envp(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
    }

    /// `directory:PATH`, unless it is already there (a relaunch must not grow the variable).
    public static func prepend(_ directory: String, to path: String) -> String {
        let entries = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !entries.contains(directory) else { return path }
        return path.isEmpty ? directory : directory + ":" + path
    }

    /// Keeps a UTF-8 locale (`fr_FR.UTF-8`, `en_US.utf8`), replaces anything else (`C`, `POSIX`, nil) with `en_US.UTF-8`.
    static func utf8Locale(_ lang: String?) -> String {
        guard let lang, !lang.isEmpty else { return "en_US.UTF-8" }
        let normalized = lang.lowercased().replacingOccurrences(of: "-", with: "")
        return normalized.contains("utf8") ? lang : "en_US.UTF-8"
    }
}
