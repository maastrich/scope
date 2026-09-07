import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// Turns a `(ThreadRecord, DriverProfile, mode)` into a `LaunchPlan`: waits for the login-shell
/// environment (cached after the first probe), prepares the profile's event adapter (the Claude Code
/// hooks settings file, see `ClaudeHooksAdapter`), then lets `LaunchPlanner` expand placeholders, resolve
/// the executable, verify the cwd and build the child environment.
@MainActor
struct ThreadLauncher {
    let env: AppEnvironment

    /// `Scope.app/Contents/Helpers/scope-hook`, or `scope-hook` from the login-shell PATH.
    func scopeHookPath(searchPATH: String) -> String {
        ScopeHookLocator.locate(bundleURL: Bundle.main.bundleURL, searchPATH: searchPATH)
    }

    func plan(record: ThreadRecord, profile: DriverProfile, scope: ScopeDeclaration, task: TaskRecord? = nil, mode: LaunchMode) async throws(LaunchError) -> LaunchPlan {
        let shell = await env.shell.environment()
        let scopeHook = scopeHookPath(searchPATH: shell.path)
        let adapterArguments = try AdapterInstaller.prepare(profile: profile, threadID: record.id, home: env.home, scopeHookPath: scopeHook)
        let values = PlaceholderValues(
            threadID: record.id.rawValue,
            resumeID: record.resumeID,
            cwd: record.cwd,
            scope: scope.path,
            task: task?.root,
            home: env.home.path,
            scopeHook: scopeHook
        )
        let variables = TerminalEnvironment.ScopeVariables(
            thread: record.id.rawValue,
            scope: scope.slug,
            scopeRoot: scope.path,
            task: task?.slug,   // SCOPE_TASK = slug (spec §4.3); SCOPE_TASK_ROOT is merged below
            sock: env.socketPath,
            home: env.home.path
        )
        var plan = try LaunchPlanner.plan(
            profile: profile,
            mode: mode,
            values: values,
            shellEnvironment: shell,
            scopeVariables: variables,
            appVersion: env.appVersion,
            adapterArguments: adapterArguments
        )
        if let task {
            plan.environment.merge(env.tasks.taskEnvironment(for: task)) { $1 }
        }
        return plan
    }
}
