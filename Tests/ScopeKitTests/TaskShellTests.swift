import Foundation
import ScopeDrivers
import Testing

@Suite("TaskShell")
struct TaskShellTests {
    let shell = ResolvedShellEnvironment(
        shell: "/bin/zsh",
        variables: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/me", "SCOPE_THREAD": "stale", "SCOPE_PORT": "9"],
        source: .interactiveLogin)
    let scope = TerminalEnvironment.ScopeVariables(
        thread: nil, scope: "acme", scopeRoot: "/Users/me/acme", task: "fix-login",
        sock: "/Users/me/.scope/scope.sock", home: "/Users/me/.scope")

    func plan(cwd: String = "/Users/me/.scope/sandboxes/acme/fix-login/api",
              task: [String: String] = ["SCOPE_TASK": "fix-login", "SCOPE_TASK_ROOT": "/Users/me/.scope/sandboxes/acme/fix-login", "SCOPE_PORT": "4310"],
              exists: Bool = true) throws(LaunchError) -> LaunchPlan {
        try TaskShell.plan(shellEnvironment: shell, cwd: cwd, scope: scope, taskEnvironment: task, appVersion: "0.27.0",
                           helpers: "/Applications/Scope.app/Contents/Helpers", theme: .light, fileExists: { _ in exists })
    }

    // MARK: Environment

    @Test("the shell is the login shell, started as one, in the task's working directory")
    func loginShell() throws {
        let plan = try plan()
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.argv0 == "-zsh")
        #expect(plan.arguments.isEmpty)
        #expect(plan.cwd == "/Users/me/.scope/sandboxes/acme/fix-login/api")
        #expect(plan.displayCommand == "zsh")
        #expect(plan.environment["PWD"] == plan.cwd)
        #expect(plan.environment["SHELL"] == "/bin/zsh")
    }

    @Test("the shell gets what a thread of the task gets, minus the thread")
    func scopeVariables() throws {
        let env = try plan().environment
        #expect(env["SCOPE_TASK"] == "fix-login")
        #expect(env["SCOPE_TASK_ROOT"] == "/Users/me/.scope/sandboxes/acme/fix-login")
        #expect(env["SCOPE_PORT"] == "4310", "the task's port, not the one the app inherited")
        #expect(env["SCOPE_HOME"] == "/Users/me/.scope")
        #expect(env["SCOPE_SOCK"] == "/Users/me/.scope/scope.sock")
        #expect(env["SCOPE_SCOPE"] == "acme")
        #expect(env["SCOPE_SCOPE_ROOT"] == "/Users/me/acme")
        #expect(env["SCOPE_THREAD"] == nil, "no thread: nothing for a hook to report to")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORFGBG"] == "0;15")
        #expect(env["PATH"]?.hasPrefix("/Applications/Scope.app/Contents/Helpers:") == true, "scope and scope-hook are on the PATH")
    }

    @Test("a thread keeps SCOPE_THREAD")
    func threadVariable() {
        var variables = scope
        variables.thread = "3f9a2c17be04"
        #expect(variables.asDictionary["SCOPE_THREAD"] == "3f9a2c17be04")
        #expect(scope.asDictionary["SCOPE_THREAD"] == nil)
    }

    @Test("a missing working directory is refused before the fork")
    func cwdMissing() {
        #expect(throws: LaunchError.cwdMissing("/gone")) { try plan(cwd: "/gone", exists: false) }
    }

    @Test("a shell nowhere on the PATH is refused")
    func shellMissing() {
        let shell = ResolvedShellEnvironment(shell: "nushell", variables: ["PATH": "/nonexistent"], source: .login)
        #expect(throws: LaunchError.self) {
            try TaskShell.plan(shellEnvironment: shell, cwd: "/", scope: scope, taskEnvironment: [:], appVersion: "0")
        }
    }

    // MARK: Tab title

    @Test("a tab says the command the terminal reports, else the shell")
    func tabTitle() {
        let cwd = "/Users/me/.scope/sandboxes/acme/fix-login/api"
        #expect(TaskShell.tabTitle(reported: nil, shell: "/bin/zsh", cwd: cwd) == "zsh")
        #expect(TaskShell.tabTitle(reported: "", shell: "/opt/homebrew/bin/fish", cwd: cwd) == "fish")
        #expect(TaskShell.tabTitle(reported: " swift test ", shell: "/bin/zsh", cwd: cwd) == "swift test")
        #expect(TaskShell.tabTitle(reported: "zsh", shell: "/bin/zsh", cwd: cwd) == "zsh")
    }

    @Test("a title that only names the directory is no command")
    func directoryTitles() {
        let cwd = "/Users/me/.scope/sandboxes/acme/fix-login/api"
        for title in [cwd, "api", "~/src/api", "/tmp", "me@mac: ~/src/api", "me@mac: /tmp"] {
            #expect(TaskShell.tabTitle(reported: title, shell: "/bin/zsh", cwd: cwd) == "zsh", "\(title)")
        }
        #expect(TaskShell.tabTitle(reported: "vim api", shell: "/bin/zsh", cwd: cwd) == "vim api")
    }

    // MARK: Footer

    @Test("the footer names the task and the port")
    func summary() {
        #expect(TaskShell.injectedSummary(["SCOPE_TASK": "fix-login", "SCOPE_PORT": "4310", "SCOPE_HOME": "/h"])
                == "SCOPE_TASK · SCOPE_PORT=4310 injected")
        #expect(TaskShell.injectedSummary(["SCOPE_TASK": "fix-login"]) == "SCOPE_TASK injected")
        #expect(TaskShell.injectedSummary(["PATH": "/bin"]) == "nothing injected")
        #expect(TaskShell.injectedVariables(["SCOPE_TASK": "t", "PATH": "/bin", "SCOPE_HOME": "/h"]) == ["SCOPE_HOME=/h", "SCOPE_TASK=t"])
    }

    // MARK: Tabs

    @Test("a new tab is shown at once, after the task's others")
    func openTabs() {
        var tabs = TaskShellTabs()
        let a = TaskShellID(), b = TaskShellID(), other = TaskShellID()
        tabs.open(a, in: "t1")
        tabs.open(other, in: "t2")
        tabs.open(b, in: "t1")
        #expect(tabs.tabs(of: "t1").map(\.id) == [a, b])
        #expect(tabs.selectedTab(of: "t1")?.id == b)
        #expect(tabs.selectedTab(of: "t2")?.id == other)
        tabs.select(a)
        #expect(tabs.selectedTab(of: "t1")?.id == a)
        #expect(tabs.selectedTab(of: "t3") == nil)
    }

    @Test("closing the shown tab moves to the one on its right, else on its left")
    func closeTabs() {
        var tabs = TaskShellTabs()
        let a = TaskShellID(), b = TaskShellID(), c = TaskShellID()
        tabs.open(a, in: "t1"); tabs.open(b, in: "t1"); tabs.open(c, in: "t1")
        tabs.select(b)
        #expect(tabs.close(b)?.id == b)
        #expect(tabs.selectedTab(of: "t1")?.id == c)
        tabs.close(c)
        #expect(tabs.selectedTab(of: "t1")?.id == a)
        tabs.select(a)
        tabs.close(a)
        #expect(tabs.selectedTab(of: "t1") == nil)
        #expect(tabs.close(a) == nil, "closing twice is nothing")
    }

    @Test("closing a tab that is not shown keeps the shown one")
    func closeOtherTab() {
        var tabs = TaskShellTabs()
        let a = TaskShellID(), b = TaskShellID()
        tabs.open(a, in: "t1"); tabs.open(b, in: "t1")
        tabs.close(a)
        #expect(tabs.selectedTab(of: "t1")?.id == b)
    }

    @Test("a task takes every one of its tabs with it, and no other task's")
    func closeAll() {
        var tabs = TaskShellTabs()
        let a = TaskShellID(), b = TaskShellID(), other = TaskShellID()
        tabs.open(a, in: "t1"); tabs.open(other, in: "t2"); tabs.open(b, in: "t1")
        let closed = tabs.closeAll(of: "t1")
        #expect(Set(closed.map(\.id)) == [a, b])
        #expect(tabs.tabs(of: "t1").isEmpty)
        #expect(tabs.selectedTab(of: "t1") == nil)
        #expect(tabs.tabs(of: "t2").map(\.id) == [other])
        #expect(tabs.selectedTab(of: "t2")?.id == other)
    }
}
