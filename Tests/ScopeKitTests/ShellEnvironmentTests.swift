import Foundation
import ScopeCore
import ScopeDrivers
import Testing

/// Temp directory holding fake shell scripts.
private struct ShellFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "scope-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Writes an executable script and returns its path.
    func script(_ name: String, _ body: String) throws -> String {
        let url = root.appending(path: name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A fake shell that appends one line to `counter` and then behaves like `/bin/sh` with the same flags.
    func countingShell() throws -> (shell: String, counter: URL) {
        let counter = root.appending(path: "counter")
        let shell = try script("counting-sh", "echo run >> '\(counter.path)'\nexec /bin/sh \"$@\"")
        return (shell, counter)
    }

    func runs(_ counter: URL) -> Int {
        guard let text = try? String(contentsOf: counter, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {
    @Test("loginShell is an absolute path")
    func loginShell() {
        let shell = ShellEnvironment.loginShell()
        #expect(shell.hasPrefix("/"))
        #expect(!shell.isEmpty)
        // With an empty passwd shell (not the case here) $SHELL then /bin/zsh would be used; the fallback is always absolute.
        #expect(ShellEnvironment.loginShell(environment: [:]).hasPrefix("/"))
    }

    @Test("/bin/sh -lc probe returns the shell's variables, PATH included")
    func probeLoginSh() async {
        guard let variables = await ShellEnvironment.probe(shell: "/bin/sh", mode: .login, timeout: .seconds(15)) else {
            // Sandboxed CI without a usable /etc/profile: nothing to assert.
            return
        }
        #expect(variables["PATH"]?.isEmpty == false)
        #expect(variables["SCOPE_ENV_PROBE"] == "1", "the probe marker variable reaches the child")
        #expect(variables["TERM"] == "dumb")
    }

    @Test("/bin/zsh -ilc marker technique (skipped gracefully when zsh cannot run)")
    func probeInteractiveZsh() async {
        guard ExecutableResolver.isExecutableFile("/bin/zsh") else { return }
        guard let variables = await ShellEnvironment.probe(shell: "/bin/zsh", mode: .interactiveLogin, timeout: .seconds(15)) else {
            return
        }
        #expect(variables["PATH"]?.contains("/usr/bin") == true)
        #expect(variables["HOME"]?.isEmpty == false)
    }

    @Test("a shell that never prints the markers yields nil")
    func probeNoMarkers() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let silent = try fixture.script("silent", "exit 0")
        #expect(await ShellEnvironment.probe(shell: silent, mode: .interactiveLogin) == nil)

        let failing = try fixture.script("failing", "exit 3")
        #expect(await ShellEnvironment.probe(shell: failing, mode: .login) == nil)

        // Only one marker printed (the script's first statement, echoed back verbatim): still nil.
        let half = try fixture.script("half", "printf '%s' \"$2\" | cut -d';' -f1")
        #expect(await ShellEnvironment.probe(shell: half, mode: .login) == nil)
    }

    @Test("a hanging shell is killed at the timeout")
    func probeTimeout() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let hanging = try fixture.script("hanging", "sleep 30")
        let clock = ContinuousClock()
        let start = clock.now
        let result = await ShellEnvironment.probe(shell: hanging, mode: .interactiveLogin, timeout: .seconds(1))
        #expect(result == nil)
        // The claim is "it does not wait for the 30 s sleep", not "it returns in exactly 1 s": a loaded CI
        // runner needs room above the timeout, and 5 s of it was not enough.
        #expect(clock.now - start < .seconds(15))
    }

    @Test("a missing shell binary yields nil")
    func probeMissingShell() async {
        #expect(await ShellEnvironment.probe(shell: "/nonexistent/fish", mode: .login) == nil)
    }

    @Test("mode .none never runs the shell")
    func probeNone() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let (shell, counter) = try fixture.countingShell()
        #expect(await ShellEnvironment.probe(shell: shell, mode: ShellProbeMode.none) == nil)
        #expect(fixture.runs(counter) == 0)
    }

    @Test("the fake shell wrapper works end to end (validates the fixture)")
    func countingShellProbe() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let (shell, counter) = try fixture.countingShell()
        let variables = await ShellEnvironment.probe(shell: shell, mode: .login, timeout: .seconds(15))
        #expect(variables?["SCOPE_ENV_PROBE"] == "1")
        #expect(fixture.runs(counter) == 1)
    }

    @Test("pathHelperPATH contains /usr/bin")
    func pathHelper() async {
        let path = await ShellEnvironment.pathHelperPATH()
        #expect(path?.split(separator: ":").contains("/usr/bin") == true)
    }
}

@Suite("ShellEnvironmentResolver")
struct ShellEnvironmentResolverTests {
    @Test("ten concurrent callers share one probe; the result is cached")
    func singleFlight() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let (shell, counter) = try fixture.countingShell()
        let resolver = ShellEnvironmentResolver(shell: shell, mode: .login, timeout: .seconds(15), base: ["BASE_ONLY": "1"])
        #expect(await resolver.isResolved == false)

        let results = await withTaskGroup(of: ResolvedShellEnvironment.self, returning: [ResolvedShellEnvironment].self) { group in
            for _ in 0..<10 {
                group.addTask { await resolver.environment() }
            }
            var collected: [ResolvedShellEnvironment] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 10)
        #expect(fixture.runs(counter) == 1)
        let first = try #require(results.first)
        #expect(results.allSatisfy { $0 == first })
        #expect(first.source == .login)
        #expect(first.shell == shell)
        #expect(first.warning == nil)
        #expect(first.variables["BASE_ONLY"] == "1", "base variables are kept under the probed ones")
        #expect(first.variables["SCOPE_ENV_PROBE"] == nil, "probe-only variables are removed")
        #expect(first.variables["TERM"] != "dumb")
        #expect(!first.path.isEmpty)
        #expect(await resolver.isResolved)
        #expect(await resolver.current == first)

        _ = await resolver.environment()
        #expect(fixture.runs(counter) == 1, "cached: no second probe")
    }

    @Test("falls back to path_helper with a warning when the shell fails, then refresh re-probes")
    func fallbackAndRefresh() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let failing = try fixture.script("failing", "exit 1")
        let resolver = ShellEnvironmentResolver(shell: failing, mode: .interactiveLogin, timeout: .seconds(15), base: ["PATH": "/only/base"])

        let resolved = await resolver.environment()
        #expect(resolved.source == .pathHelper)
        #expect(resolved.path.contains("/usr/bin"))
        #expect(resolved.path != "/only/base")
        let warning = try #require(resolved.warning)
        #expect(warning.contains("-ilc"))
        #expect(warning.contains("-lc"))
        #expect(warning.contains("exited with status 1"))
        #expect(warning.contains("/etc/paths"))

        let (shell, counter) = try fixture.countingShell()
        // A refresh with a working probe is not possible on the same resolver (the shell is fixed), so
        // check that refresh runs the probe again on a fresh resolver.
        let counting = ShellEnvironmentResolver(shell: shell, mode: .login, timeout: .seconds(15), base: [:])
        _ = await counting.environment()
        #expect(fixture.runs(counter) == 1)
        let refreshed = await counting.refresh()
        #expect(fixture.runs(counter) == 2)
        #expect(refreshed.source == .login)
        _ = await counting.refresh(mode: ShellProbeMode.none)
        #expect(fixture.runs(counter) == 2, "mode .none skips the shell")
    }

    @Test("a hanging shell times out and the warning says so")
    func timeoutWarning() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let hanging = try fixture.script("hanging", "sleep 30")
        let resolver = ShellEnvironmentResolver(shell: hanging, mode: .login, timeout: .milliseconds(500), base: [:])
        let resolved = await resolver.environment()
        #expect(resolved.source != .login)
        #expect(resolved.warning?.contains("timed out after 0.5 s") == true)
    }
}
