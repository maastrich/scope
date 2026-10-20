import Foundation
import ScopeCore

/// A task's shell pane (spec §7): the user's login shell in the task's working directory, with the `SCOPE_*`
/// variables a thread of the task gets — minus the driver and minus the thread. It is a pane of the reading
/// column, not a thread: nothing in the sidebar, no record on disk, and it goes when the task does.
public enum TaskShell {
    /// The plan for one shell of the task: `shellEnvironment.shell` started as a login shell (`argv0` dashed, the way
    /// the bundled `shell` driver does it), in `cwd`, with the environment `TerminalEnvironment.build` gives a
    /// thread plus the task's own variables (`SCOPE_TASK_ROOT`, `SCOPE_PORT`).
    public static func plan(
        shellEnvironment: ResolvedShellEnvironment,
        cwd: String,
        scope: TerminalEnvironment.ScopeVariables,
        taskEnvironment: [String: String],
        appVersion: String,
        helpers: String? = nil,
        theme: TerminalTheme = .dark,
        fileExists: (String) -> Bool = { LaunchPlanner.directoryExists($0) }
    ) throws(LaunchError) -> LaunchPlan {
        let shell = shellEnvironment.shell
        guard let executable = ExecutableResolver.resolve(shell, path: shellEnvironment.path, shell: shell) else {
            throw .commandNotFound(command: shell, searchedPATH: shellEnvironment.path, shell: shell)
        }
        guard fileExists(cwd) else { throw .cwdMissing(cwd) }
        var environment = TerminalEnvironment.build(
            base: shellEnvironment.variables, shell: shell, cwd: cwd, scope: scope, driverEnv: [:],
            appVersion: appVersion, helpers: helpers, theme: theme)
        environment.merge(taskEnvironment) { $1 }
        let name = shellName(executable)
        return LaunchPlan(executable: executable, argv0: "-" + name, arguments: [], environment: environment, cwd: cwd,
                          displayCommand: name)
    }

    /// `zsh` for `/bin/zsh`: what a tab says when the shell has not said anything.
    public static func shellName(_ shell: String) -> String {
        let name = (shell as NSString).lastPathComponent
        return name.isEmpty ? "shell" : name
    }

    /// The title of a tab: the command the terminal reported (OSC 0/2, as zsh and fish prompts set it while a
    /// command runs), else the shell's name. A title that only names the directory — what those prompts set
    /// between two commands — is no command and counts as nothing: the tab says `zsh` again.
    public static func tabTitle(reported: String?, shell: String, cwd: String) -> String {
        let name = shellName(shell)
        guard let reported else { return name }
        let title = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isDirectoryTitle(title, cwd: cwd), title != name else { return name }
        return title
    }

    /// Whether `title` is a path (`~/src/api`, `/tmp`), the directory's name, or `user@host: path` as a stock zsh
    /// prompt writes it.
    static func isDirectoryTitle(_ title: String, cwd: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (cwd as NSString).standardizingPath
        let tilde = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let last = (path as NSString).lastPathComponent
        let body = title.contains(": ") ? String(title[title.range(of: ": ")!.upperBound...]) : title
        if body == path || body == tilde || body == last { return true }
        return body.hasPrefix("/") || body.hasPrefix("~")
    }

    /// The footer's account of what the shell got: `SCOPE_TASK · SCOPE_PORT=4310 injected` — the task and its port,
    /// since those are what a command in the shell would look for; the rest is listed by `injectedVariables`.
    public static func injectedSummary(_ environment: [String: String]) -> String {
        var parts: [String] = []
        if environment["SCOPE_TASK"] != nil { parts.append("SCOPE_TASK") }
        if let port = environment["SCOPE_PORT"] { parts.append("SCOPE_PORT=\(port)") }
        guard !parts.isEmpty else { return "nothing injected" }
        return parts.joined(separator: " · ") + " injected"
    }

    /// Every `SCOPE_*` variable of the shell as `KEY=value`, sorted: the footer's tooltip.
    public static func injectedVariables(_ environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix("SCOPE_") }.sorted().map { "\($0)=\(environment[$0] ?? "")" }
    }
}

/// The identity of one shell of a task, for the tabs; never written to disk.
public struct TaskShellID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString }

    public var description: String { rawValue }
}

/// The tabs of the shell panes, every task's together, and which tab each task shows. Pure: what the pane
/// draws, and what a task takes with it when it closes; the sessions behind the tabs belong to the app.
public struct TaskShellTabs: Sendable, Equatable {
    public struct Tab: Hashable, Sendable {
        public var id: TaskShellID
        /// The task's id, as a string so the registry needs nothing from the task model.
        public var task: String

        public init(id: TaskShellID, task: String) {
            self.id = id
            self.task = task
        }
    }

    public private(set) var tabs: [Tab] = []
    private var selection: [String: TaskShellID] = [:]

    public init() {}

    public func tabs(of task: String) -> [Tab] { tabs.filter { $0.task == task } }

    public func tab(_ id: TaskShellID) -> Tab? { tabs.first { $0.id == id } }

    /// The tab the task's pane shows: the one picked last, else the newest.
    public func selectedTab(of task: String) -> Tab? {
        let own = tabs(of: task)
        if let id = selection[task], let tab = own.first(where: { $0.id == id }) { return tab }
        return own.last
    }

    /// A new tab, after the task's others, and shown at once.
    public mutating func open(_ id: TaskShellID, in task: String) {
        tabs.append(Tab(id: id, task: task))
        selection[task] = id
    }

    public mutating func select(_ id: TaskShellID) {
        guard let tab = tab(id) else { return }
        selection[tab.task] = id
    }

    /// Closes a tab; the pane then shows the one that was to its right, else to its left (a browser's rule).
    @discardableResult
    public mutating func close(_ id: TaskShellID) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let closed = tabs.remove(at: index)
        guard selection[closed.task] == id else { return closed }
        let remaining = tabs(of: closed.task)
        let after = tabs[index...].first { $0.task == closed.task }
        selection[closed.task] = (after ?? remaining.last)?.id
        return closed
    }

    /// Every tab of the task, gone: what an archive or a close takes with it.
    @discardableResult
    public mutating func closeAll(of task: String) -> [Tab] {
        let closed = tabs(of: task)
        tabs.removeAll { $0.task == task }
        selection[task] = nil
        return closed
    }
}
