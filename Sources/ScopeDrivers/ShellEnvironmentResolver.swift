import Foundation
import ScopeCore

/// The environment a thread is based on, and where it came from.
public struct ResolvedShellEnvironment: Sendable, Equatable {
    /// How the variables were obtained, best first.
    public enum Source: String, Sendable {
        /// `<shell> -ilc` succeeded.
        case interactiveLogin
        /// `<shell> -lc` succeeded (after `-ilc` failed, or because the preference says so).
        case login
        /// Only `/usr/libexec/path_helper` could be used: the app environment plus the `/etc/paths` PATH.
        case pathHelper
        /// The app's own environment, unchanged.
        case processEnvironment
    }

    /// The login shell, e.g. `/opt/homebrew/bin/fish`.
    public var shell: String
    /// The resolved variables.
    public var variables: [String: String]
    /// Which step of the fallback chain produced `variables`.
    public var source: Source
    /// Human-readable reason when a fallback was used, e.g. "fish -ilc timed out after 10 s; using /etc/paths".
    public var warning: String?

    public init(shell: String, variables: [String: String], source: Source, warning: String? = nil) {
        self.shell = shell
        self.variables = variables
        self.source = source
        self.warning = warning
    }

    /// `PATH`, or `""`.
    public var path: String { variables["PATH"] ?? "" }
}

/// Resolves the login-shell environment once and caches it. Concurrent callers share one probe (single flight).
///
/// Fallback chain for `.interactiveLogin`: `-ilc` → `-lc` → `path_helper` → process environment.
/// For `.login`: `-lc` → `path_helper` → process environment. For `.none`: `path_helper` → process environment.
public actor ShellEnvironmentResolver {
    private let shell: String
    private var mode: ShellProbeMode
    private let timeout: Duration
    private let base: [String: String]
    private var cached: ResolvedShellEnvironment?
    private var inFlight: Task<ResolvedShellEnvironment, Never>?

    /// - Parameters:
    ///   - shell: the login shell to probe (passwd shell by default).
    ///   - mode: the `Preferences.shellProbe` value.
    ///   - timeout: per probe attempt.
    ///   - base: the variables the probe result is layered on (the app's environment by default).
    public init(
        shell: String = ShellEnvironment.loginShell(),
        mode: ShellProbeMode = .interactiveLogin,
        timeout: Duration = .seconds(10),
        base: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.shell = shell
        self.mode = mode
        self.timeout = timeout
        self.base = base
    }

    /// The resolved environment; probes on the first call and returns the cached value afterwards.
    public func environment() async -> ResolvedShellEnvironment {
        if let cached { return cached }
        return await run()
    }

    /// Probes again (optionally with a different mode) and replaces the cached value.
    public func refresh(mode: ShellProbeMode? = nil) async -> ResolvedShellEnvironment {
        if let mode { self.mode = mode }
        cached = nil
        return await run()
    }

    /// `true` once a probe has completed.
    public var isResolved: Bool { cached != nil }

    /// The last resolved value without triggering a probe.
    public var current: ResolvedShellEnvironment? { cached }

    private func run() async -> ResolvedShellEnvironment {
        if let inFlight { return await inFlight.value }
        let shell = shell
        let mode = mode
        let timeout = timeout
        let base = base
        let task = Task { await Self.resolve(shell: shell, mode: mode, timeout: timeout, base: base) }
        inFlight = task
        let result = await task.value
        // A `refresh` may have started a newer probe while this one ran; only the newest one owns the cache.
        if inFlight == task {
            cached = result
            inFlight = nil
        }
        return result
    }

    /// The fallback chain. `nonisolated` and static: pure function of its inputs, runs off the actor.
    static func resolve(
        shell: String,
        mode: ShellProbeMode,
        timeout: Duration,
        base: [String: String]
    ) async -> ResolvedShellEnvironment {
        var warnings: [String] = []
        let shellName = (shell as NSString).lastPathComponent

        let attempts: [(ShellProbeMode, ResolvedShellEnvironment.Source)]
        switch mode {
        case .interactiveLogin: attempts = [(.interactiveLogin, .interactiveLogin), (.login, .login)]
        case .login: attempts = [(.login, .login)]
        case .none: attempts = []
        }

        for (probeMode, source) in attempts {
            let flags = ShellEnvironment.shellFlags(for: probeMode) ?? ""
            switch await ShellEnvironment.probeOutcome(shell: shell, mode: probeMode, timeout: timeout) {
            case .success(let probed):
                var variables = base.merging(probed) { _, fromShell in fromShell }
                variables.removeValue(forKey: "SCOPE_ENV_PROBE")
                if probed["TERM"] == "dumb" { variables["TERM"] = base["TERM"] }
                return ResolvedShellEnvironment(
                    shell: shell,
                    variables: variables,
                    source: source,
                    warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
                )
            case .timedOut(let after):
                warnings.append("\(shellName) \(flags) timed out after \(Self.format(after))")
            case .launchFailed(let message):
                warnings.append("\(shellName) \(flags) could not be started (\(message))")
            case .exited(let code):
                warnings.append("\(shellName) \(flags) exited with status \(code)")
            case .missingMarkers:
                warnings.append("\(shellName) \(flags) printed no environment")
            case .skipped:
                continue
            }
        }

        if let path = await ShellEnvironment.pathHelperPATH() {
            var variables = base
            variables["PATH"] = path
            warnings.append("using the PATH from /etc/paths")
            return ResolvedShellEnvironment(
                shell: shell,
                variables: variables,
                source: .pathHelper,
                warning: mode == .none ? nil : warnings.joined(separator: "; ")
            )
        }

        warnings.append("using the app's own environment")
        return ResolvedShellEnvironment(
            shell: shell,
            variables: base,
            source: .processEnvironment,
            warning: warnings.joined(separator: "; ")
        )
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds == seconds.rounded() { return "\(Int(seconds)) s" }
        return String(format: "%.1f s", seconds)
    }
}
