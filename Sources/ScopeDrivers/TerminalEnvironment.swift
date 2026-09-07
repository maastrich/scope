import Foundation

/// Builds the complete environment of a PTY child.
///
/// SwiftTerm's `startProcess(environment:)` *replaces* the environment (raw `execve` envp), so every
/// variable the child needs has to be here: the resolved login-shell environment, the terminal variables,
/// the `SCOPE_*` variables and the driver profile's `env`.
public enum TerminalEnvironment {
    /// The variables Scope injects into every thread so hooks and tools can find their way back.
    public struct ScopeVariables: Sendable, Equatable {
        /// `SCOPE_THREAD` — the thread id.
        public var thread: String
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

        public init(thread: String, scope: String, scopeRoot: String, task: String? = nil, sock: String, home: String) {
            self.thread = thread
            self.scope = scope
            self.scopeRoot = scopeRoot
            self.task = task
            self.sock = sock
            self.home = home
        }

        /// `SCOPE_THREAD`, `SCOPE_SCOPE`, `SCOPE_SCOPE_ROOT`, `SCOPE_TASK` (omitted if nil), `SCOPE_SOCK`, `SCOPE_HOME`.
        public var asDictionary: [String: String] {
            var variables = [
                "SCOPE_THREAD": thread,
                "SCOPE_SCOPE": scope,
                "SCOPE_SCOPE_ROOT": scopeRoot,
                "SCOPE_SOCK": sock,
                "SCOPE_HOME": home,
            ]
            if let task { variables["SCOPE_TASK"] = task }
            return variables
        }
    }

    /// Variables that describe the *app's* process, not the child's, and must not leak into it.
    public static let strippedKeys: Set<String> = [
        "OLDPWD", "SHLVL", "_", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "SCOPE_ENV_PROBE",
    ]

    /// `TERM` value for every thread.
    public static let term = "xterm-256color"

    /// `base` → + `TERM`, `COLORTERM`, `LANG` (kept if UTF-8, else `en_US.UTF-8`), `TERM_PROGRAM=Scope`,
    /// `TERM_PROGRAM_VERSION`, `SHELL`, `PWD=cwd` → − `strippedKeys` → + scope variables → + `driverEnv`
    /// (already expanded by the caller).
    public static func build(
        base: [String: String],
        shell: String,
        cwd: String,
        scope: ScopeVariables,
        driverEnv: [String: String],
        appVersion: String
    ) -> [String: String] {
        var environment = base
        environment["TERM"] = term
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = utf8Locale(environment["LANG"])
        environment["TERM_PROGRAM"] = "Scope"
        environment["TERM_PROGRAM_VERSION"] = appVersion
        environment["SHELL"] = shell
        environment["PWD"] = cwd
        for key in strippedKeys { environment.removeValue(forKey: key) }
        for (key, value) in scope.asDictionary { environment[key] = value }
        for (key, value) in driverEnv { environment[key] = value }
        return environment
    }

    /// `"KEY=VALUE"` entries sorted by key, deterministic for tests and logs.
    public static func envp(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
    }

    /// Keeps a UTF-8 locale (`fr_FR.UTF-8`, `en_US.utf8`), replaces anything else (`C`, `POSIX`, nil) with `en_US.UTF-8`.
    static func utf8Locale(_ lang: String?) -> String {
        guard let lang, !lang.isEmpty else { return "en_US.UTF-8" }
        let normalized = lang.lowercased().replacingOccurrences(of: "-", with: "")
        return normalized.contains("utf8") ? lang : "en_US.UTF-8"
    }
}
