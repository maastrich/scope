import os

/// Unified-logging categories shared by every module.
///
/// Read them with `log stream --predicate 'subsystem == "dev.scope.app"'`. Every `Problem`
/// surfaced in the UI is also written here so a bug report carries the full story.
public enum Log {
    /// The subsystem every category belongs to.
    public static let subsystem = "dev.scope.app"

    /// App lifecycle, bootstrap, configuration.
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// Scope declaration, repo discovery.
    public static let scopes = Logger(subsystem: subsystem, category: "scopes")
    /// Thread launch, exit, persistence.
    public static let threads = Logger(subsystem: subsystem, category: "threads")
    /// Git subprocesses.
    public static let git = Logger(subsystem: subsystem, category: "git")
    /// File-system watching.
    public static let fs = Logger(subsystem: subsystem, category: "fs")
    /// Adapter socket and hook events.
    public static let hooks = Logger(subsystem: subsystem, category: "hooks")
}
