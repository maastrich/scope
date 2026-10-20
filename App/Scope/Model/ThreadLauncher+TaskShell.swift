import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

extension ThreadLauncher {
    /// The plan of a shell of the task's shell pane: the login shell, in `threadCwd`, with the environment a thread
    /// of the task gets (`TaskShell.plan`) and the sandbox git hooks a thread gets too — a `git push --force` from
    /// the pane is no better than one from a thread.
    func taskShellPlan(task: TaskRecord, scope: ScopeDeclaration) async throws(LaunchError) -> LaunchPlan {
        let shell = await env.shell.environment()
        let theme: TerminalTheme = TerminalAppearance.palette().isDark ? .dark : .light
        let variables = TerminalEnvironment.ScopeVariables(
            thread: nil, scope: scope.slug, scopeRoot: scope.path, task: task.slug, sock: env.socketPath, home: env.home.path)
        var plan = try TaskShell.plan(
            shellEnvironment: shell, cwd: task.threadCwd.path, scope: variables,
            taskEnvironment: env.tasks.taskEnvironment(for: task), appVersion: env.appVersion,
            helpers: helpersDirectory, theme: theme)
        do {
            let hooks = try SandboxGitHooks.install(home: env.home)
            plan.environment = SandboxGitHooks.environment(adding: hooks.path, to: plan.environment)
        } catch {
            Log.threads.error("could not install the sandbox git hooks: \(String(describing: error), privacy: .public)")
        }
        return plan
    }
}
