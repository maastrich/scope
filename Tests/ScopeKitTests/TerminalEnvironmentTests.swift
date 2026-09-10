import Foundation
import ScopeDrivers
import Testing

@Suite("TerminalEnvironment")
struct TerminalEnvironmentTests {
    let scope = TerminalEnvironment.ScopeVariables(
        thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/Users/me/acme", task: nil,
        sock: "/Users/me/.scope/scope.sock", home: "/Users/me/.scope"
    )

    func build(base: [String: String], driverEnv: [String: String] = [:], scope: TerminalEnvironment.ScopeVariables? = nil) -> [String: String] {
        TerminalEnvironment.build(
            base: base, shell: "/opt/homebrew/bin/fish", cwd: "/Users/me/acme/api",
            scope: scope ?? self.scope, driverEnv: driverEnv, appVersion: "0.1.0"
        )
    }

    @Test("base is merged and the terminal variables are set")
    func terminalVariables() {
        let env = build(base: ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me", "SHELL": "/bin/zsh"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "Scope")
        #expect(env["TERM_PROGRAM_VERSION"] == "0.1.0")
        #expect(env["SHELL"] == "/opt/homebrew/bin/fish", "SHELL follows the resolved login shell")
        #expect(env["PWD"] == "/Users/me/acme/api")
    }

    @Test("LANG is kept when UTF-8 and replaced otherwise")
    func lang() {
        #expect(build(base: ["LANG": "fr_FR.UTF-8"])["LANG"] == "fr_FR.UTF-8")
        #expect(build(base: ["LANG": "en_GB.utf8"])["LANG"] == "en_GB.utf8")
        #expect(build(base: ["LANG": "C"])["LANG"] == "en_US.UTF-8")
        #expect(build(base: ["LANG": "POSIX"])["LANG"] == "en_US.UTF-8")
        #expect(build(base: [:])["LANG"] == "en_US.UTF-8")
    }

    @Test("app-process variables are stripped")
    func strippedKeys() {
        var base: [String: String] = ["KEEP": "1"]
        for key in TerminalEnvironment.strippedKeys { base[key] = "x" }
        let env = build(base: base)
        for key in TerminalEnvironment.strippedKeys {
            #expect(env[key] == nil, "\(key)")
        }
        #expect(env["KEEP"] == "1")
        #expect(TerminalEnvironment.strippedKeys.isSuperset(of: ["OLDPWD", "SHLVL", "_", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "SCOPE_ENV_PROBE"]))
    }

    @Test("SCOPE_* variables are injected; SCOPE_TASK only when set")
    func scopeVariables() {
        let env = build(base: [:])
        #expect(env["SCOPE_THREAD"] == "3f9a2c17be04")
        #expect(env["SCOPE_SCOPE"] == "acme")
        #expect(env["SCOPE_SCOPE_ROOT"] == "/Users/me/acme")
        #expect(env["SCOPE_SOCK"] == "/Users/me/.scope/scope.sock")
        #expect(env["SCOPE_HOME"] == "/Users/me/.scope")
        #expect(env["SCOPE_TASK"] == nil)
        #expect(env.keys.filter { $0.hasPrefix("SCOPE_") }.count == 5)

        var withTask = scope
        withTask.task = "/Users/me/.scope/sandboxes/acme/auth"
        let taskEnv = build(base: [:], scope: withTask)
        #expect(taskEnv["SCOPE_TASK"] == "/Users/me/.scope/sandboxes/acme/auth")
        #expect(withTask.asDictionary.count == 6)
        #expect(scope.asDictionary.count == 5)
    }

    @Test("driver env overrides base and terminal variables, and scope variables")
    func driverEnvOverrides() {
        let env = build(
            base: ["PATH": "/usr/bin", "EDITOR": "vim"],
            driverEnv: ["EDITOR": "cursor -w", "TERM": "xterm", "SCOPE_SCOPE": "other", "NEW": "1"]
        )
        #expect(env["EDITOR"] == "cursor -w")
        #expect(env["TERM"] == "xterm")
        #expect(env["SCOPE_SCOPE"] == "other")
        #expect(env["NEW"] == "1")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test("envp is K=V sorted by key")
    func envp() {
        let envp = TerminalEnvironment.envp(["B": "2", "A": "1=x", "C": ""])
        #expect(envp == ["A=1=x", "B=2", "C="])
        #expect(TerminalEnvironment.envp([:]) == [])
    }

    @Test("build never returns an empty environment and is deterministic")
    func deterministic() {
        let first = build(base: ["Z": "1", "A": "2"])
        let second = build(base: ["A": "2", "Z": "1"])
        #expect(first == second)
        #expect(TerminalEnvironment.envp(first) == TerminalEnvironment.envp(second))
        #expect(first.count >= 12)
    }

    /// The app's own `Contents/Helpers` goes first on the PATH: that is what makes `scope` and `scope-hook`
    /// work inside a thread with nothing installed.
    @Test func theHelpersFolderLeadsThePath() {
        let environment = TerminalEnvironment.build(
            base: ["PATH": "/usr/bin:/bin"], shell: "/bin/zsh", cwd: "/tmp",
            scope: TerminalEnvironment.ScopeVariables(thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/tmp",
                                                      sock: "/tmp/scope.sock", home: "/tmp/home"),
            driverEnv: [:], appVersion: "1.0", helpers: "/Applications/Scope.app/Contents/Helpers"
        )
        #expect(environment["PATH"] == "/Applications/Scope.app/Contents/Helpers:/usr/bin:/bin")
    }

    /// A relaunch must not grow the variable.
    @Test func theHelpersFolderIsAddedOnce() {
        #expect(TerminalEnvironment.prepend("/helpers", to: "/helpers:/usr/bin") == "/helpers:/usr/bin")
        #expect(TerminalEnvironment.prepend("/helpers", to: "") == "/helpers")
        #expect(TerminalEnvironment.prepend("/helpers", to: "/usr/bin") == "/helpers:/usr/bin")
    }
}
