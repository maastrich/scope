import Foundation
import Synchronization

/// The environment every `Subprocess.run` child starts from, before its own overrides.
///
/// An app opened from Finder or the Dock inherits launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). Threads and
/// setups get the login shell's environment, but git, `gh` and the rest used to start from the app's own: a git
/// whose config runs `git-lfs filter-process` then failed on `git-lfs: command not found` although Homebrew had it.
/// The app installs a base here — the fallback at launch, the probed shell environment once it is known — and every
/// child the package starts builds on it. Nothing installed (the command line, `scope-hook`, the tests) keeps the
/// process environment as it is.
public enum SubprocessEnvironment {
    /// Where the installed variables came from.
    public enum Source: Sendable, Equatable {
        /// The login shell's environment (`-ilc` / `-lc`): what a thread gets.
        case probed
        /// No usable probe yet, or it failed: the app's environment, `PATH` widened with `fallbackDirectories`.
        case fallback
    }

    /// Variables that describe the shell the probe ran in, not the user's setup: a child must not inherit them.
    public static let volatileKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "SCOPE_ENV_PROBE"]

    private static let installed = Mutex<[String: String]?>(nil)

    /// The base for a child: the installed variables, or the process environment when nothing was installed.
    public static var current: [String: String] {
        installed.withLock { $0 } ?? ProcessInfo.processInfo.environment
    }

    /// `true` once the app installed a base.
    public static var isInstalled: Bool { installed.withLock { $0 != nil } }

    /// Replaces the base of every later child. Only the app calls this: a global, so tests use `compose` instead.
    public static func install(_ variables: [String: String]) {
        installed.withLock { $0 = variables }
    }

    /// The directories where tools installed outside the system live, in the order a shell would usually list them.
    /// `home` is `~`.
    public static func fallbackDirectories(home: String) -> (front: [String], back: [String]) {
        (front: ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"],
         back: ["\(home)/.local/bin", "\(home)/.cargo/bin"])
    }

    /// The base to install for `variables`.
    ///
    /// - `.probed`: the shell's variables as a thread sees them, minus `volatileKeys`; the fallback directories it
    ///   lacks go at the end of `PATH`, so nothing the shell put first is shadowed and git never gets less than a
    ///   thread.
    /// - `.fallback`: `variables` (the app's environment, or `/etc/paths`), with the Homebrew prefixes in front of
    ///   `PATH` and `~/.local/bin`, `~/.cargo/bin` behind it.
    ///
    /// `isDirectory` keeps only the fallback directories that exist (injected for tests).
    public static func compose(
        _ variables: [String: String],
        source: Source,
        home: String = NSHomeDirectory(),
        isDirectory: (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    ) -> [String: String] {
        var result = variables
        for key in volatileKeys { result.removeValue(forKey: key) }
        let current = (variables["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let extra = fallbackDirectories(home: home)
        let path: [String]
        switch source {
        case .probed: path = current + (extra.front + extra.back).filter(isDirectory)
        case .fallback: path = extra.front.filter(isDirectory) + current + extra.back.filter(isDirectory)
        }
        var seen = Set<String>()
        result["PATH"] = path.filter { seen.insert($0).inserted }.joined(separator: ":")
        return result
    }
}
