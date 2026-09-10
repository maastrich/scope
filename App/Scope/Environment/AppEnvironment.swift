import Foundation
import ScopeAdapters
import ScopeControl
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
    /// The one listener on `socketPath`: hook events in, control requests in and out.
    let hooks: ControlSocketServer?
    /// Mirror of the thread ids the app owns; the socket server validates senders against it off main.
    let knownThreads: KnownThreads
    let hookSink: HookSink
    /// Holds the `ControlService` until `AppModel` exists to provide it.
    let controls: ControlSink
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
         hooks: ControlSocketServer?,
         knownThreads: KnownThreads,
         hookSink: HookSink,
         controls: ControlSink,
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
        self.controls = controls
        self.uiState = uiState
        self.startupProblems = startupProblems
    }

    /// The real thing: `~/.scope` (or `SCOPE_HOME`), layout ensured, hook server started.
    /// A hook server failure becomes a problem, never a crash: the app works without adapters.
    ///
    /// A Debug build lives in `~/.scope-debug` instead. Running one beside the installed copy otherwise means
    /// two apps sharing one config, one set of thread records and — worse — one hook socket, so a driver's
    /// events reach whichever of the two happens to be listening.
    static func live() -> AppEnvironment {
        var problems: [Problem] = []
        #if DEBUG
        let home = ScopeHome.url(folderName: ".scope-debug")
        #else
        let home = ScopeHome.url()
        #endif
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
        let controls = ControlSink()
        var hooks: ControlSocketServer?
        do {
            hooks = try ControlSocketServer(
                path: socketPath,
                isKnownThread: { knownThreads.contains($0) },
                hookSink: { event in sink.deliver(event) },
                controls: controls,
                onFailure: { error in
                    Log.hooks.error("hook socket failed: \(String(describing: error), privacy: .public)")
                }
            )
            hooks?.start()
        } catch {
            problems.append(Problem(
                severity: .warning,
                title: "Adapter socket unavailable",
                detail: "Could not listen on \(socketPath): \(String(describing: error))\n\nThreads still run; driver hooks cannot report their state and the `scope` command line cannot reach the app.",
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
            controls: controls,
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
