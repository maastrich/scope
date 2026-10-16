import AppKit
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
    /// `<home>/threads/<id>.activity.json`, beside each record.
    let threadActivity: ThreadActivityStore
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
    /// `<home>/usage`: the local log of what is used in the app (`Usage`). Off until the model has read the preference,
    /// so nothing is written for a user who turned it off.
    let usage: UsageRecorder
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
        self.threadActivity = ThreadActivityStore(home: home)
        self.drivers = drivers
        self.shell = shell
        self.git = git
        self.taskRecords = TaskRecordStore(home: home)
        self.tasks = TaskManager(home: home, registry: git, store: taskRecords,
                            ports: PortAllocator.range(debugBuild: BuildFlavor.isDebug))
        self.graphStore = GraphStore(home: home)
        self.hooks = hooks
        self.knownThreads = knownThreads
        self.hookSink = hookSink
        self.controls = controls
        self.uiState = uiState
        self.usage = UsageRecorder(log: UsageLog(home: home), enabled: false)
        self.startupProblems = startupProblems
    }

    /// The real thing: `~/.scope` (or `SCOPE_HOME`), layout ensured, hook server started.
    /// A hook server failure becomes a problem, never a crash: the app works without adapters.
    ///
    /// A Debug build lives in `~/.scope-debug` instead. Running one beside the installed copy otherwise means
    /// two apps sharing one config, one set of thread records and — worse — one hook socket, so a driver's
    /// events reach whichever of the two happens to be listening.
    static func live() -> AppEnvironment {
        let resolution = AppHome.resolve(debugBuild: BuildFlavor.isDebug)
        // Decided before anything is created or bound: a home refused here must not have been touched first.
        let home = resolution.home
        var problems = resolution.problems
        let socketPath = SocketPath.resolve(home: home)
        // Before the layout, the stores and the auto-relaunch: a second app on a home somebody is running would
        // rewrite its config and thread records and start its threads a second time.
        if UnixSocketServer.isListening(at: socketPath) { refuseSecondInstance(home: home, socketPath: socketPath) }
        dropInheritedThreadEnvironment()
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
            uiState: UIStateStore(home: home),
            startupProblems: problems
        )
    }

    /// Removes from this process what a thread of another Scope left in its environment.
    ///
    /// Started from a thread, the app holds that thread's `SCOPE_*` variables and its git-hooks override. The
    /// home is already resolved by now; everything after this point — the login-shell probe, the app's own
    /// `git`, the threads it opens — builds on the process environment and would pass them on: a thread
    /// opened outside a task kept the other app's `SCOPE_TASK_ROOT` and `SCOPE_PORT` and ran its hooks.
    private static func dropInheritedThreadEnvironment() {
        let current = ProcessInfo.processInfo.environment
        let clean = SandboxGitHooks.withoutInheritedThread(current)
        for key in current.keys where clean[key] == nil { unsetenv(key) }
        for (key, value) in clean where current[key] != value { setenv(key, value, 1) }
    }

    /// Says why this instance will not start, then quits.
    ///
    /// Reached with `open -n`, or by two worktrees running their Debug build at once: both are
    /// `dev.maastrich.scope.debug` on `~/.scope-debug`, and macOS does not stop the second from launching.
    private static func refuseSecondInstance(home: URL, socketPath: String) -> Never {
        Log.app.error("refusing to start: \(socketPath, privacy: .public) is already served")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Another Scope is already running on \(home.path)"
        alert.informativeText = "Something is listening on \(socketPath). Two apps on one home overwrite each other's "
            + "config and thread records, and a driver's events reach whichever of them is listening.\n\n"
            + "This is \(Bundle.main.bundlePath) (pid \(ProcessInfo.processInfo.processIdentifier)). "
            + "Quit the other one, or start this one with another SCOPE_HOME."
        alert.addButton(withTitle: "Quit")
        NSApplication.shared.activate()
        alert.runModal()
        exit(1)
    }

    /// Swaps in the registry built around the located git (before any `ScopeState` exists).
    func useGit(at path: String) {
        guard path != git.gitPath else { return }
        git = GitClientRegistry(gitPath: path)
        tasks = TaskManager(home: home, registry: git, store: taskRecords,
                            ports: PortAllocator.range(debugBuild: BuildFlavor.isDebug))
    }

    /// A generator over the current git registry; `level1` is the driver-backed pass (`nil` = level 0 only).
    func makeGraphGenerator(level1: Level1Generator?) -> GraphGenerator {
        GraphGenerator(store: graphStore, registry: git, level1: level1)
    }
}
