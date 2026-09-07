import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeGraph
import ScopeTasks

/// Receives adapter events from the hook socket and hands them to whoever registered (the `AppModel`).
/// Exists because the socket server is built before the model.
@MainActor
final class HookSink {
    var handler: (@MainActor (AdapterEvent) -> Void)?

    func deliver(_ event: AdapterEvent) {
        handler?(event)
    }
}

/// Composition root: `SCOPE_HOME`, the on-disk layout, every store and service. Built synchronously
/// (cheap) by `ScopeApp`; nothing here talks to the network or waits on a subprocess.
@MainActor
final class AppEnvironment {
    let home: URL
    let socketPath: String
    let appVersion: String
    let config: ConfigStore
    let threadRecords: ThreadRecordStore
    let drivers: DriverRegistry
    let shell: ShellEnvironmentResolver
    /// Replaced once `GitLocator` has found the right git (bootstrap); `/usr/bin/git` until then.
    private(set) var git: GitClientRegistry
    let taskRecords: TaskRecordStore
    /// Rebuilt with `git` by `useGit` (before any task is loaded); `TaskManager.loadAll` runs after that.
    private(set) var tasks: TaskManager
    /// `<home>/graph/<slug>.json` (spec §4.6).
    let graphStore: GraphStore
    let hooks: HookSocketServer?
    /// Mirror of the thread ids the app owns; the socket server validates senders against it off main.
    let knownThreads: KnownThreads
    let hookSink: HookSink
    let uiState: UIStateStore
    /// Problems met while building the environment, reported once the `ProblemCenter` exists.
    let startupProblems: [Problem]

    init(home: URL,
         socketPath: String,
         appVersion: String,
         config: ConfigStore,
         threadRecords: ThreadRecordStore,
         drivers: DriverRegistry,
         shell: ShellEnvironmentResolver,
         git: GitClientRegistry,
         hooks: HookSocketServer?,
         knownThreads: KnownThreads,
         hookSink: HookSink,
         uiState: UIStateStore,
         startupProblems: [Problem]) {
        self.home = home
        self.socketPath = socketPath
        self.appVersion = appVersion
        self.config = config
        self.threadRecords = threadRecords
        self.drivers = drivers
        self.shell = shell
        self.git = git
        self.taskRecords = TaskRecordStore(home: home)
        self.tasks = TaskManager(home: home, registry: git, store: taskRecords)
        self.graphStore = GraphStore(home: home)
        self.hooks = hooks
        self.knownThreads = knownThreads
        self.hookSink = hookSink
        self.uiState = uiState
        self.startupProblems = startupProblems
    }

    /// The real thing: `~/.scope` (or `SCOPE_HOME`), layout ensured, hook server started.
    /// A hook server failure becomes a problem, never a crash: the app works without adapters.
    static func live() -> AppEnvironment {
        var problems: [Problem] = []
        let home = ScopeHome.url()
        do {
            try ScopeHome.ensureLayout(at: home)
        } catch {
            problems.append(Problem(
                severity: .error,
                title: "Could not create \(home.path)",
                detail: String(describing: error),
                actions: [.reveal(home.deletingLastPathComponent().path)]
            ))
        }
        let socketPath = SocketPath.resolve(home: home)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

        let knownThreads = KnownThreads()
        let sink = HookSink()
        var hooks: HookSocketServer?
        do {
            hooks = try HookSocketServer(
                path: socketPath,
                isKnownThread: { knownThreads.contains($0) },
                sink: { event in sink.deliver(event) },
                onFailure: { error in
                    Log.hooks.error("hook socket failed: \(String(describing: error), privacy: .public)")
                }
            )
            hooks?.start()
        } catch {
            problems.append(Problem(
                severity: .warning,
                title: "Adapter socket unavailable",
                detail: "Could not listen on \(socketPath): \(String(describing: error))\n\nThreads still run; driver hooks cannot report their state.",
                actions: [.reveal(home.path)]
            ))
        }

        return AppEnvironment(
            home: home,
            socketPath: socketPath,
            appVersion: version,
            config: ConfigStore(home: home),
            threadRecords: ThreadRecordStore(home: home),
            drivers: DriverRegistry(home: home),
            shell: ShellEnvironmentResolver(),
            git: GitClientRegistry(gitPath: GitLocator.systemGit),
            hooks: hooks,
            knownThreads: knownThreads,
            hookSink: sink,
            uiState: UIStateStore(),
            startupProblems: problems
        )
    }

    /// Swaps in the registry built around the located git (before any `ScopeState` exists).
    func useGit(at path: String) {
        guard path != git.gitPath else { return }
        git = GitClientRegistry(gitPath: path)
        tasks = TaskManager(home: home, registry: git, store: taskRecords)
    }

    /// A generator over the current git registry; `level1` is the driver-backed pass (`nil` = level 0 only).
    func makeGraphGenerator(level1: Level1Generator?) -> GraphGenerator {
        GraphGenerator(store: graphStore, registry: git, level1: level1)
    }
}
