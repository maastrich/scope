import Foundation
import ScopeCore
import ScopeDrivers

/// Turns a `(ThreadRecord, DriverProfile, mode)` into a `LaunchPlan`: waits for the login-shell
/// environment (cached after the first probe), then lets `LaunchPlanner` expand placeholders, resolve
/// the executable, verify the cwd and build the child environment.
@MainActor
struct ThreadLauncher {
    let env: AppEnvironment

    func plan(record: ThreadRecord, profile: DriverProfile, scope: ScopeDeclaration, mode: LaunchMode) async throws(LaunchError) -> LaunchPlan {
        let shell = await env.shell.environment()
        let values = PlaceholderValues(
            threadID: record.id.rawValue,
            resumeID: record.resumeID,
            cwd: record.cwd,
            scope: scope.path,
            task: nil,
            home: env.home.path
        )
        let variables = TerminalEnvironment.ScopeVariables(
            thread: record.id.rawValue,
            scope: scope.slug,
            scopeRoot: scope.path,
            task: nil,
            sock: env.socketPath,
            home: env.home.path
        )
        return try LaunchPlanner.plan(
            profile: profile,
            mode: mode,
            values: values,
            shellEnvironment: shell,
            scopeVariables: variables,
            appVersion: env.appVersion
        )
    }
}
