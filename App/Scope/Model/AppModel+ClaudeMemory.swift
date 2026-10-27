import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks

/// Claude Code's auto memory for task threads (`ClaudeMemory`): the context files name it, and `scope memory`
/// gathers what tasks and other clones left behind (`ClaudeMemoryRecovery`).
extension AppModel {
    /// Where the threads launched now keep their memory, as the context files must say: `nil` with the preference
    /// off, or when the user's own Claude Code settings decide.
    func claudeMemoryLocator() async -> ClaudeMemory.Locator? {
        guard config.preferences.claudeSharedMemory else { return nil }
        let shell = await env.shell.environment()
        return ClaudeMemory.Locator.resolve(environment: shell.variables, userHome: NSHomeDirectory())
    }

    /// Hands the locator to the task manager, for the context files written from now on.
    func syncClaudeMemory() {
        Task { [weak self] in
            guard let self else { return }
            let locator = await claudeMemoryLocator()
            await env.tasks.setClaudeMemory(locator)
        }
    }

    /// The memory folders of a task's threads, for the inspector: its scope's and each repository's. Empty when
    /// Scope leaves the folder to Claude Code.
    func claudeMemoryPlacements(of record: TaskRecord) async -> [ClaudeMemory.Placement] {
        guard let locator = await claudeMemoryLocator() else { return [] }
        let own = ClaudeMemory.placement(cwd: record.threadCwd.path(percentEncoded: false), task: record, locator: locator)
        return [own] + ClaudeMemory.companions(of: own, task: record, locator: locator)
    }

    /// `scope memory`: the report, and the copy with `apply`.
    func recoverClaudeMemory(apply: Bool, claudeDir: String?) async -> String {
        let locator: ClaudeMemory.Locator
        if let claudeDir {
            locator = ClaudeMemory.Locator(configDirectory: URL(fileURLWithPath: (claudeDir as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            let shell = await env.shell.environment()
            var environment = shell.variables
            // The report covers the folders even when the user picked one of their own for new sessions.
            environment["CLAUDE_CODE_PROJECT_DIR_NAME"] = nil
            environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = nil
            locator = ClaudeMemory.Locator.resolve(environment: environment, userHome: NSHomeDirectory(), userSettings: { _ in nil })
                ?? ClaudeMemory.Locator(configDirectory: URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude"))
        }
        let scopes = self.scopes.map { scope in
            (slug: scope.declaration.slug, name: scope.declaration.name, root: scope.url.path(percentEncoded: false),
             repos: scope.repos.map(\.id))
        }
        let tasks = await env.tasks.allTasks
        let sandboxes = ScopeHome.sandboxesURL(home: env.home).path(percentEncoded: false)
        return await Task.detached {
            let disk = ClaudeMemoryRecovery.Disk.live
            let declared = scopes.map { scope in
                ClaudeMemoryRecovery.Scope(slug: scope.slug, name: scope.name, root: scope.root, repos: scope.repos.map { path in
                    let checkout = path == "." ? scope.root : (scope.root as NSString).appendingPathComponent(path)
                    return ClaudeMemoryRecovery.Repo(relativePath: path, remote: disk.remote(checkout))
                })
            }
            let plan = ClaudeMemoryRecovery.plan(locator: locator, sandboxesRoot: sandboxes, scopes: declared, tasks: tasks, disk: disk)
            guard apply else { return ClaudeMemoryRecovery.report(plan) }
            let applied = ClaudeMemoryRecovery.apply(plan, projects: locator.projectsDirectory.path(percentEncoded: false))
            return ClaudeMemoryRecovery.report(plan, applied: applied)
        }.value
    }
}
