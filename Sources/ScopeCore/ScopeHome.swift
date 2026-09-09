import Foundation

/// Location of Scope's home directory (`~/.scope` by default, overridable with `SCOPE_HOME`).
///
/// Nothing in `Sources/*` reads the real home implicitly: every store takes a `home: URL` in its
/// initializer and only the app's composition root calls `ScopeHome.url()`. Tests pass a temp directory.
///
/// Gotcha: an app launched from Finder or the Dock inherits launchd's minimal environment, so a
/// `SCOPE_HOME` exported in `.zshrc` is invisible to it (only `launchctl setenv SCOPE_HOME …` reaches
/// GUI apps).
public enum ScopeHome {
    /// `SCOPE_HOME` from `environment` (tilde expanded) when set and non-empty, else `~/<folderName>`.
    ///
    /// - Parameter folderName: the default folder under the user's home. The app passes `.scope-debug` for a
    ///   Debug build so a build you run from Xcode never shares its config, its thread records, its sandboxes
    ///   or its hook socket with the copy installed in /Applications.
    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        folderName: String = ".scope"
    ) -> URL {
        if let override = environment["SCOPE_HOME"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        // Not sandboxed, so this is the real home (in a sandbox it would be the container).
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Creates `drivers/`, `graph/`, `sandboxes/` and `threads/` under `home` (idempotent) and returns `home`.
    @discardableResult
    public static func ensureLayout(at home: URL) throws -> URL {
        for sub in ["drivers", "graph", "sandboxes", "threads"] {
            try FileManager.default.createDirectory(
                at: home.appending(path: sub, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        return home
    }

    /// `<home>/config.json`
    public static func configURL(home: URL) -> URL {
        home.appending(path: "config.json", directoryHint: .notDirectory)
    }

    /// `<home>/drivers/`
    public static func driversURL(home: URL) -> URL {
        home.appending(path: "drivers", directoryHint: .isDirectory)
    }

    /// `<home>/graph/`
    public static func graphURL(home: URL) -> URL {
        home.appending(path: "graph", directoryHint: .isDirectory)
    }

    /// `<home>/threads/`
    public static func threadsURL(home: URL) -> URL {
        home.appending(path: "threads", directoryHint: .isDirectory)
    }

    /// `<home>/sandboxes/`
    public static func sandboxesURL(home: URL) -> URL {
        home.appending(path: "sandboxes", directoryHint: .isDirectory)
    }
}
