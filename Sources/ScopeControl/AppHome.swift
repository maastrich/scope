import Foundation
import ScopeAdapters
import ScopeCore

/// The home an app build starts on, and what it had to refuse to get there.
///
/// This is the app's side of the question `ControlEndpoint` answers for a client. The CLI and the hook *rely* on
/// inheriting `SCOPE_HOME` from the thread they run in; an app build must not, because a Debug build started
/// from a thread of the installed copy (`make run` from an agent, Xcode opened from a Scope terminal) would then
/// run against the production home. `ScopeHome.url` keeps its meaning for the former; only the app calls this.
public enum AppHome {
    public struct Resolution: Sendable, Equatable {
        /// The home to use.
        public var home: URL
        /// A `SCOPE_HOME` that was dropped because it came with the thread the build was launched from.
        public var ignoredInherited: String?
        /// The production home a Debug build was pointed at and did not take.
        public var refusedProduction: String?

        public init(home: URL, ignoredInherited: String? = nil, refusedProduction: String? = nil) {
            self.home = home
            self.ignoredInherited = ignoredInherited
            self.refusedProduction = refusedProduction
        }

        /// What the app shows at startup. A home that silently changed under a developer is how a Debug build
        /// ended up driving real scopes for a while before anyone noticed, so neither case is quiet.
        public var problems: [Problem] {
            var problems: [Problem] = []
            if let refusedProduction {
                problems.append(Problem(
                    severity: .error,
                    title: "This Debug build was pointed at the production home",
                    detail: "SCOPE_HOME resolved to \(refusedProduction), the home of the installed Scope. "
                        + "A Debug build never runs there: it is using \(home.path) instead.\n\n"
                        + "Pick any other folder to run against a scratch home.",
                    actions: [.reveal(home.path)]
                ))
            }
            if let ignoredInherited {
                problems.append(Problem(
                    severity: .info,
                    title: "Ignored the SCOPE_HOME of the thread this build was launched from",
                    detail: "SCOPE_HOME=\(ignoredInherited) was inherited from a Scope thread, not chosen. "
                        + "Using \(home.path).",
                    actions: [.dismiss]
                ))
            }
            return problems
        }
    }

    /// Resolves the home for an app build.
    ///
    /// A Release build honours `SCOPE_HOME` however it arrived. A Debug build:
    /// - drops a `SCOPE_HOME` it *inherited* from a thread (see `inheritedHome`);
    /// - obeys one set on purpose, from a plain terminal or with `open --env` inside a thread;
    /// - never lands on the production home, whichever way it got there.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debugBuild: Bool
    ) -> Resolution {
        guard debugBuild else { return Resolution(home: ScopeHome.appURL(environment: environment, debugBuild: false)) }

        var effective = environment
        let inherited = inheritedHome(in: environment)
        if inherited != nil {
            effective.removeValue(forKey: "SCOPE_HOME")
        } else {
            // A home chosen on purpose from inside a thread: `ScopeHome.appURL` reads `SCOPE_THREAD` alone as
            // "inherited", so it must not see it.
            effective.removeValue(forKey: "SCOPE_THREAD")
        }
        let home = ScopeHome.appURL(environment: effective, debugBuild: true)
        guard isProductionHome(home) else { return Resolution(home: home, ignoredInherited: inherited) }
        return Resolution(home: ScopeHome.appURL(environment: [:], debugBuild: true),
                          ignoredInherited: inherited, refusedProduction: home.path)
    }

    /// The `SCOPE_HOME` of `environment` when it came with a thread rather than from someone who meant it.
    ///
    /// `SCOPE_THREAD` says the process descends from a thread. `SCOPE_SOCK` says whether the home is still the
    /// one that thread was given: Scope exports the two as a pair, so a `SCOPE_HOME` whose socket is not
    /// `SCOPE_SOCK` was overridden on the way (`open --env SCOPE_HOME=/tmp/demo` from an agent's shell, which is
    /// how a throwaway instance is started). Without that second test the override would be thrown away and the
    /// throwaway instance would land in `~/.scope-debug`, on top of the developer's own Debug session.
    static func inheritedHome(in environment: [String: String]) -> String? {
        guard let home = environment["SCOPE_HOME"], !home.isEmpty,
              let thread = environment["SCOPE_THREAD"], !thread.isEmpty else { return nil }
        guard let socket = environment["SCOPE_SOCK"], !socket.isEmpty else { return home }
        let exported = SocketPath.resolve(home: ScopeHome.url(environment: ["SCOPE_HOME": home]))
        return socket == exported ? home : nil
    }

    /// `true` when `home` is `~/.scope`, reached by any spelling: a symlink, a trailing slash, another case
    /// (the default volume is case-insensitive).
    public static func isProductionHome(_ home: URL) -> Bool {
        canonical(home) == canonical(ScopeHome.url(environment: [:]))
    }

    private static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.lowercased()
    }
}
