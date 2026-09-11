import AppKit
import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks
import SwiftUI

/// The root store: scopes, threads, selection, and every user action. One per app.
@MainActor
@Observable
final class AppModel {
    let env: AppEnvironment
    let problems = ProblemCenter()
    let notifier = ThreadNotifier()
    /// ⌘K.
    var paletteShown = false
    private(set) var config: ScopeConfig = .empty
    /// Sidebar order == `config.scopes` order.
    private(set) var scopes: [ScopeState] = []
    /// Creation order; tabs filter by scope.
    private(set) var threads: [ThreadSession] = []
    /// Creation order; the sidebar filters by scope. Mutated by `AppModel+Tasks` only.
    var tasks: [TaskState] = []
    /// The Delta inspector's state; follows `currentTask`.
    let delta: DeltaModel
    /// The Graph inspector's state; follows `currentScope`.
    let graph: GraphModel
    /// The Base inspector's state; follows `baseRepo`.
    let base: BaseModel
    /// The PRs inspector (`gh pr list` of the picked repo).
    let pullRequests: PullRequestsModel
    /// Comments on the Delta diff of the followed task.
    let review: ReviewModel
    /// Messages waiting for a thread to finish its turn (`deliver`), per thread.
    var pendingDeliveries: [ThreadID: [PendingDelivery]] = [:]
    /// Scope the New Task sheet is open for (`nil` = closed).
    var newTaskScopeID: ScopeID?
    private(set) var drivers = LoadedDrivers(profiles: [])
    private(set) var shellStatus: ShellStatus = .probing
    private(set) var isBootstrapped = false
    /// Follows Vibe Island's jump log (`AppModel+Attention`); `nil` until bootstrap.
    @ObservationIgnored var vibeIslandJumps: VibeIslandJumpWatcher?
    /// Threads that exited live: the tab stays (greyed) while the toast shows; see `threadExited`.
    private(set) var exitNotices: [ThreadExitNotice] = []
    /// Threads closed in the last 30 s, most recent last (⇧⌘T restores the last one).
    private(set) var recentlyClosed: [ClosedThread] = []

    /// Drives the sidebar highlight and, through `syncThreadFromSelection`, the scene: a thread row selects
    /// its tab, a task row its last thread, a scope or repo row shows the scope's empty view.
    var selection: SidebarItem? {
        didSet {
            guard !isRestoringUIState else { return }
            if let scopeID = scopeID(of: selection), scopeID != currentScopeID {
                currentScopeID = scopeID
            }
            syncThreadFromSelection()
            persistUIState()
        }
    }

    /// The scope the sidebar shows (its tasks, threads and repositories). Follows the selection — selecting an
    /// item of another scope switches — and is remembered across launches; `nil` means "the first declared".
    var currentScopeID: ScopeID? {
        didSet { if !isRestoringUIState, currentScopeID != oldValue { persistUIState() } }
    }

    /// Driver last opened per scope (restored from the UI state): what ⌘T reaches for first.
    var lastDriverByScope: [ScopeID: String] = [:]

    /// Drives the scene. Kept in sync with `selection`.
    var selectedThreadID: ThreadID? {
        didSet {
            if let id = selectedThreadID, let session = session(id) {
                lastThreadByScope[session.record.scopeID] = id
                revealThread(session)
            }
            clearNotifications(for: selectedThreadID)
            acknowledgeShownResult()
            if !isRestoringUIState { persistUIState() }
        }
    }

    var inspectorShown = false {
        didSet {
            // Asking for the inspector is asking for the window's layout back.
            if inspectorShown, threadMaximized { threadMaximized = false }
            if !isRestoringUIState { persistUIState() }
        }
    }

    /// The current thread fills the window, sidebar and inspector out of the way (⌘M). Never saved: a launch
    /// starts from the layout the user chose, not from a mode they may have forgotten they were in.
    private(set) var threadMaximized = false

    var inspectorTab: InspectorTab = .graph {
        didSet { if !isRestoringUIState { persistUIState() } }
    }

    /// Width of the inspector column in points (320…520).
    var inspectorWidth: Double = UIState.defaultInspectorWidth {
        didSet { if !isRestoringUIState, inspectorWidth != oldValue { persistUIState() } }
    }

    /// Exited threads close themselves when their toast goes (Settings ▸ General).
    var autoCloseExitedThreads: Bool {
        config.preferences.autoCloseExitedThreads
    }

    @ObservationIgnored private var lastThreadByScope: [ScopeID: ThreadID] = [:]
    @ObservationIgnored private var undoTimers: [ThreadID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isRestoringUIState = false
    @ObservationIgnored private var reportedShellWarning = false
    @ObservationIgnored private var launcher: ThreadLauncher
    /// Threads being closed by the user (`close`) or by termination: their exit is not a live exit.
    @ObservationIgnored private var closingThreads: Set<ThreadID> = []
    @ObservationIgnored private(set) var isTerminating = false
    /// Threads that were running when the app went down and stayed stopped at launch for a reason the user did not
    /// choose; the banner says which. Cleared by the thread's next launch.
    var autoRelaunchBlocks: [ThreadID: AutoRelaunchSkip] = [:]
    /// Setups in flight, per task: a thread of the task waits for its task's entry before it launches. The token
    /// tells a finished run it is still the latest one before it removes itself.
    @ObservationIgnored var setupRuns: [TaskID: (token: UUID, run: Task<Void, Never>)] = [:]

    init(env: AppEnvironment) {
        self.env = env
        self.launcher = ThreadLauncher(env: env)
        self.delta = DeltaModel(env: env, problems: problems)
        self.graph = GraphModel(env: env, problems: problems)
        self.base = BaseModel(env: env, problems: problems)
        self.pullRequests = PullRequestsModel(problems: problems)
        self.review = ReviewModel(home: env.home, problems: problems)
        problems.onAction = { [weak self] action in self?.perform(action) }
        env.hookSink.handler = { [weak self] event in self?.handle(event) }
        // The CLI and the MCP server reach the app through this and nothing else.
        env.controls.service = AppControlService(model: self)
        for problem in env.startupProblems { problems.report(problem) }
    }

    // MARK: Lookup

    var currentScope: ScopeState? {
        currentScopeID.flatMap(scope) ?? scopes.first
    }

    /// The scope a sidebar item belongs to (threads and tasks through the model).
    func scopeID(of item: SidebarItem?) -> ScopeID? {
        switch item {
        case .scope(let id), .repo(let id, _):
            return id
        case .thread(let id):
            return session(id)?.record.scopeID
        case .task(let id):
            return task(id)?.scopeID
        case nil:
            return nil
        }
    }

    /// The scope switcher: shows `id` in the sidebar with its header row selected.
    func selectScope(_ id: ScopeID) {
        guard scope(id) != nil else { return }
        selection = .scope(id)
    }

    /// The Repositories section of the current scope (View ▸ Show Repositories).
    func toggleRepositories() {
        guard let scope = currentScope else { return }
        scope.reposShown.toggle()
        persistUIState()
    }

    /// ⌘M: the current thread takes the whole window, or gives it back. Only a thread can be maximized.
    func toggleThreadMaximized() {
        if threadMaximized {
            threadMaximized = false
        } else if currentThread != nil {
            threadMaximized = true
        }
    }

    /// Leaves the maximized thread and touches nothing else (the sidebar came back by hand, the thread went).
    func restoreLayout() {
        threadMaximized = false
    }

    /// ⌥⌘I. While a thread is maximized the inspector is hidden rather than off, so the toggle means "show
    /// it" — which brings the rest of the layout back too.
    func toggleInspector() {
        if threadMaximized {
            inspectorShown = true
        } else {
            inspectorShown.toggle()
        }
    }

    var currentThread: ThreadSession? {
        guard let id = selectedThreadID, let session = session(id) else { return nil }
        // The scene only shows a thread of the current scope.
        if let scope = currentScope, session.record.scopeID != scope.id { return nil }
        return session
    }

    func scope(_ id: ScopeID) -> ScopeState? {
        scopes.first { $0.id == id }
    }

    func session(_ id: ThreadID) -> ThreadSession? {
        threads.first { $0.id == id }
    }

    func threads(in scope: ScopeID) -> [ThreadSession] {
        threads.filter { $0.record.scopeID == scope }
    }

    func task(_ id: TaskID) -> TaskState? {
        tasks.first { $0.id == id }
    }

    /// Non-archived tasks of a scope, creation order.
    func tasks(in scope: ScopeID) -> [TaskState] {
        tasks.filter { $0.scopeID == scope && !$0.isArchived }
    }

    func threads(in task: TaskID) -> [ThreadSession] {
        threads.filter { $0.record.taskID == task.rawValue }
    }

    /// Threads whose cwd is not a task sandbox (scope root or a base).
    func scopeLevelThreads(in scope: ScopeID) -> [ThreadSession] {
        threads.filter { $0.record.scopeID == scope && $0.record.taskID == nil }
    }

    func task(of session: ThreadSession) -> TaskState? {
        session.record.taskID.flatMap(TaskID.init(rawValue:)).flatMap(task)
    }

    /// The task the Delta inspector and ⌘T follow, derived from `selection` alone: a task row or a thread
    /// of a task. A scope or repo row has no task.
    var currentTask: TaskState? {
        switch selection {
        case .task(let id): task(id)
        case .thread(let id): session(id).flatMap(task(of:))
        case .scope, .repo, nil: nil
        }
    }

    /// Where ⌘T (menu, footer, palette) opens the next thread.
    var newThreadTarget: NewThreadTarget? {
        switch selection {
        case .scope(let id):
            return scope(id).map { .scopeRoot($0) }
        case .repo(let id, let relativePath):
            guard let scope = scope(id) else { return nil }
            return relativePath.isEmpty ? .scopeRoot(scope) : .repoBase(scope, relativePath: relativePath)
        case .task(let id):
            return task(id).map { .task($0) }
        case .thread(let id):
            guard let session = session(id), let scope = scope(session.record.scopeID) else { return nil }
            if let task = task(of: session) { return .task(task) }
            if case .repoBase(let relativePath) = session.record.cwdKind, !relativePath.isEmpty {
                return .repoBase(scope, relativePath: relativePath)
            }
            return .scopeRoot(scope)
        case nil:
            return currentScope.map { .scopeRoot($0) }
        }
    }

    /// Where the sidebar's New Thread button opens one: the current context, but never inside a task — a thread
    /// in a task is asked for on the task itself (its context menu). A selected repository stays a base thread,
    /// which is loose too.
    var looseThreadTarget: NewThreadTarget? {
        switch newThreadTarget {
        case .task(let task): scope(task.scopeID).map { .scopeRoot($0) }
        case let other: other
        }
    }

    /// `"in acme"`, `"in auth-refresh"`, `"in api (base)"` — for the New Thread tooltips and the palette hint.
    var newThreadTargetDescription: String? { description(of: newThreadTarget) }

    /// The same, for the sidebar's New Thread button.
    var looseThreadTargetDescription: String? { description(of: looseThreadTarget) }

    private func description(of target: NewThreadTarget?) -> String? {
        switch target {
        case .scopeRoot(let scope): "in \(scope.name)"
        case .repoBase(let scope, let relativePath): "in \(scope.repo(relativePath: relativePath)?.shortName ?? relativePath) (base)"
        case .task(let task): "in \(task.name)"
        case nil: nil
        }
    }

    /// `"acme · auth-refresh"`, `"acme · api (base)"` or `"acme"`: what the scene and inspector follow.
    var contextDescription: String? {
        switch newThreadTarget {
        case .scopeRoot(let scope): scope.name
        case .repoBase(let scope, let relativePath): "\(scope.name) · \(scope.repo(relativePath: relativePath)?.shortName ?? relativePath) (base)"
        case .task(let task): "\(scope(task.scopeID)?.name ?? task.record.scopeName) · \(task.name)"
        case nil: nil
        }
    }

    /// ⌘T: a thread in `newThreadTarget` with the default driver (or `driverID`).
    @discardableResult
    func newThreadInCurrentContext(driverID: String? = nil) async -> ThreadSession? {
        await newThread(at: newThreadTarget, driverID: driverID)
    }

    /// The sidebar's New Thread button: a loose thread (`looseThreadTarget`), never one inside a task.
    @discardableResult
    func newLooseThread(driverID: String? = nil) async -> ThreadSession? {
        await newThread(at: looseThreadTarget, driverID: driverID)
    }

    private func newThread(at target: NewThreadTarget?, driverID: String?) async -> ThreadSession? {
        switch target {
        case .scopeRoot(let scope):
            return await newThread(in: scope.id, driverID: driverID)
        case .repoBase(let scope, let relativePath):
            return await newThread(in: scope.id, driverID: driverID, cwdKind: .repoBase(relativePath: relativePath))
        case .task(let task):
            return await newThread(in: task.scopeID, driverID: driverID, taskID: task.id)
        case nil:
            return nil
        }
    }

    /// The tab / row label: duplicates of the same title in a scope are numbered in creation order
    /// (`acme`, `acme 2`). The driver is not in the title — the row's icon says which one it is.
    func displayTitle(for session: ThreadSession) -> String {
        let twins = threads(in: session.record.scopeID).filter { $0.record.title == session.record.title }
        guard twins.count > 1, let index = twins.firstIndex(where: { $0.id == session.id }), index > 0 else { return session.title }
        let title = session.title
        if let separator = title.range(of: " · ") {
            return "\(title[..<separator.lowerBound]) \(index + 1)\(title[separator.lowerBound...])"
        }
        return "\(title) \(index + 1)"
    }

    /// The OSC title when the process set one that differs from the label.
    func secondaryTitle(for session: ThreadSession) -> String? {
        guard let reported = session.terminalTitle, reported != session.title, reported != displayTitle(for: session) else { return nil }
        return reported
    }

    /// The profile for an id, falling back to `shell`, then the first profile.
    func profile(id: String?) -> DriverProfile? {
        if let id, let profile = drivers.profile(id: id) { return profile }
        return preferredProfile
    }

    /// The driver a new thread gets when nothing says otherwise: the one last opened in this scope, then the
    /// preference, then the first agent profile installed.
    ///
    /// Reaching for the last one is what makes ⌘T stop asking: a scope you drive with Claude Code keeps
    /// giving you Claude Code, and the shell is a choice you make rather than the one you are given.
    var preferredProfile: DriverProfile? {
        if let scope = currentScopeID, let id = lastDriverByScope[scope], let profile = drivers.profile(id: id) {
            return profile
        }
        if let profile = drivers.profile(id: config.preferences.defaultDriverID) { return profile }
        // No stored choice: an agent, not a shell — that is what the app is for.
        return drivers.profiles.first { $0.id != "shell" } ?? drivers.profiles.first
    }

    /// Id of `preferredProfile`, for the views that pass a driver id around.
    var preferredDriverID: String? { preferredProfile?.id }

    // MARK: Bootstrap

    /// §(d).5: stores in parallel, scopes built and scanned, records rebound, UI state restored.
    func bootstrap() async {
        startBadgeTracking()
        guard !isBootstrapped else { return }
        let skipAutoRelaunch = AppServices.shiftHeldAtLaunch || NSEvent.modifierFlags.contains(.shift)
        startActivationTracking()

        // Kicked off, not awaited: the probe can take seconds on a slow rc file.
        startShellProbe()
        let driverTask = Task { [env] () -> LoadedDrivers in
            do {
                try await env.drivers.installBuiltins()
            } catch {
                Log.app.error("installing bundled drivers failed: \(String(describing: error), privacy: .public)")
            }
            return await env.drivers.load()
        }

        async let configLoad = env.config.load()
        async let recordsLoad = env.threadRecords.loadAll()
        async let gitLocate = Self.locateGit()

        let (loadedConfig, configProblem) = await configLoad
        config = loadedConfig
        switch configProblem {
        case .corrupt(let backup, let underlying):
            problems.error("config.json was unreadable and has been moved aside",
                           detail: "\(backup.path)\n\n\(underlying)",
                           actions: [.reveal(backup.path, title: "Reveal backup")])
        case .unsupportedVersion(let version):
            problems.error("config.json was written by a newer Scope (schema \(version))",
                           detail: "Nothing will be saved until Scope is updated.",
                           actions: [.reveal(env.config.url.path)])
        case nil:
            break
        }

        switch await gitLocate {
        case .success(let installation):
            env.useGit(at: installation.path)
        case .failure(let error):
            problems.error(error.title, detail: error.detail)
        }

        drivers = await driverTask.value
        reportDriverProblems()

        scopes = config.scopes.map { ScopeState(declaration: $0, git: env.git, problems: problems) }
        for scope in scopes {
            scope.startWatching()
            Task { await scope.rescan() }
        }

        let taskProblems = await env.tasks.loadAll()
        if !taskProblems.isEmpty {
            problems.warn("\(taskProblems.count) task \(taskProblems.count == 1 ? "record" : "records") could not be loaded",
                          detail: taskProblems.map { "\($0.file.lastPathComponent): \($0.message)" }.joined(separator: "\n"),
                          actions: [.reveal(env.taskRecords.directory.path)])
        }
        tasks = await env.tasks.allTasks.map { TaskState(record: $0, git: env.git) }
        for task in tasks where !task.isArchived {
            task.startWatching()
            task.refresh()
        }

        let (records, recordProblems) = await recordsLoad
        if !recordProblems.isEmpty {
            problems.warn("\(recordProblems.count) thread \(recordProblems.count == 1 ? "record" : "records") could not be loaded",
                          detail: recordProblems.map { "\($0.file.lastPathComponent): \($0.message)" }.joined(separator: "\n"),
                          actions: [.reveal(env.threadRecords.directory.path)])
        }
        let restore = ThreadRestorer.restore(records, scopes: config.scopes)
        for record in restore.rebound {
            await env.threadRecords.save(record)
        }
        if !restore.orphans.isEmpty {
            problems.warn("\(restore.orphans.count) thread \(restore.orphans.count == 1 ? "record belongs" : "records belong") to scopes that are no longer declared",
                          detail: restore.orphans.map { "\($0.title) — \($0.scopeRoot)" }.joined(separator: "\n"),
                          actions: [.reveal(env.threadRecords.directory.path)])
        }
        for record in restore.restored {
            var profile = profile(id: record.driverID)
            if profile?.id != record.driverID {
                problems.warn("Driver \(record.driverID) not found for \(record.title)",
                              detail: "Relaunch will use \(profile?.name ?? "Shell").",
                              scope: record.scopeID, actions: [.reveal(ScopeHome.driversURL(home: env.home).path)])
            }
            if profile == nil {
                profile = DriverProfile(id: "shell", name: "Shell", command: "$SHELL", loginShell: true)
            }
            guard let profile else { continue }
            register(ThreadSession(record: record, profile: profile))
        }
        env.knownThreads.replaceAll(Set(threads.map(\.id)))

        restoreUIState()
        await autoRelaunchThreads(orphans: restore.orphans, skippedOnce: skipAutoRelaunch)
        startFollowingVibeIsland()
        isBootstrapped = true
        Log.app.info("bootstrapped: \(self.scopes.count) scopes, \(self.threads.count) threads")
    }

    private static func locateGit() async -> Result<GitInstallation, GitLocatorError> {
        do {
            return .success(try await GitLocator().locate())
        } catch let error as GitLocatorError {
            return .failure(error)
        } catch {
            return .failure(GitLocatorError(searched: [GitLocator.systemGit]))
        }
    }

    private func startShellProbe(refresh: Bool = false) {
        shellStatus = .probing
        let mode = config.preferences.shellProbe
        Task { [env] in
            let resolved = refresh ? await env.shell.refresh(mode: mode) : await env.shell.environment()
            switch resolved.source {
            case .interactiveLogin, .login:
                shellStatus = .ready(resolved)
            case .pathHelper, .processEnvironment:
                shellStatus = .fallback(resolved)
            }
            if let warning = resolved.warning, !reportedShellWarning {
                reportedShellWarning = true
                problems.warn("Shell environment fallback", detail: warning,
                              actions: [ProblemAction(title: "Re-probe Shell", kind: .reprobeShell),
                                        ProblemAction(title: "Open Settings", kind: .openSettings)])
            }
        }
    }

    private func reportDriverProblems() {
        for problem in drivers.problems {
            problems.warn("Driver profile \(problem.file.lastPathComponent) is invalid", detail: problem.message,
                          actions: [.reveal(problem.file.path)])
        }
    }

    // MARK: UI state

    private func restoreUIState() {
        let state = env.uiState.load()
        isRestoringUIState = true
        defer { isRestoringUIState = false }
        for scope in scopes {
            scope.reposShown = state.reposShown.contains(scope.id)
            scope.looseThreadsShown = !state.looseThreadsCollapsed.contains(scope.id)
        }
        inspectorShown = state.inspectorVisible
        inspectorTab = state.inspectorTab
        inspectorWidth = min(max(state.inspectorWidth, UIState.inspectorWidthRange.lowerBound), UIState.inspectorWidthRange.upperBound)
        lastDriverByScope = state.lastDrivers
        switch state.selectedItem {
        case .scope(let id) where scope(id) != nil:
            selection = state.selectedItem
            selectedThreadID = nil
        case .repo(let id, _) where scope(id) != nil:
            selection = state.selectedItem
            selectedThreadID = nil
        case .thread(let id) where session(id) != nil:
            selection = state.selectedItem
            selectedThreadID = id
        case .task(let id) where task(id) != nil:
            selection = state.selectedItem
            if let thread = state.selectedThread, let session = session(thread), session.record.taskID == id.rawValue {
                selectedThreadID = thread
            } else {
                selectedThreadID = threads(in: id).first?.id
            }
        default:
            selection = nil
        }
        currentScopeID = scopeID(of: selection) ?? state.currentScope.flatMap(scope)?.id ?? scopes.first?.id
        if selection == nil, let scope = currentScope {
            if let first = threads(in: scope.id).first {
                selection = .thread(first.id)
                selectedThreadID = first.id
            } else {
                selection = .scope(scope.id)
            }
        }
    }

    private func persistUIState() {
        var state = UIState()
        state.selectedItem = selection
        state.selectedThread = selectedThreadID
        state.currentScope = currentScopeID
        state.reposShown = Set(scopes.filter(\.reposShown).map(\.id))
        state.looseThreadsCollapsed = Set(scopes.filter { !$0.looseThreadsShown }.map(\.id))
        state.inspectorVisible = inspectorShown
        state.inspectorTab = inspectorTab
        state.inspectorWidth = inspectorWidth
        state.lastDrivers = lastDriverByScope
        env.uiState.save(state)
    }

    /// Called by the sidebar when the Repositories section of a scope is toggled.
    func expansionChanged() {
        persistUIState()
    }

    private func syncThreadFromSelection() {
        switch selection {
        case .thread(let id):
            selectedThreadID = id
        case .scope, .repo:
            // The scene shows the scope's empty view / repo context; no thread is active.
            selectedThreadID = nil
        case .task(let id):
            // Picking a task you are already inside changes nothing: you keep the thread you were reading.
            // Coming from anywhere else — another task, a loose thread — it opens the task at its first thread,
            // rather than leaving a terminal on screen that has nothing to do with the row you just clicked.
            let own = threads(in: id)
            if let current = selectedThreadID, own.contains(where: { $0.id == current }) { return }
            selectedThreadID = own.first?.id
        case nil:
            selectedThreadID = nil
        }
    }

    /// The sidebar is the only thread switcher: a thread that becomes active must be visible in it, so the
    /// task holding it unfolds.
    private func revealThread(_ session: ThreadSession) {
        guard let task = task(of: session), !task.isExpanded else { return }
        task.isExpanded = true
    }

    // MARK: Config

    private func saveConfig() {
        let config = config
        Task { await env.config.save(config) }
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        let before = config.preferences
        change(&config.preferences)
        guard config.preferences != before else { return }
        saveConfig()
        if config.preferences.shellProbe != before.shellProbe {
            reprobeShell()
        }
    }

    func reprobeShell() {
        reportedShellWarning = false
        startShellProbe(refresh: true)
    }

    func reloadDrivers() async {
        drivers = await env.drivers.reload()
        reportDriverProblems()
    }

    // MARK: Scopes

    /// Declares folders as scopes: deduplicated against the config by real path, slug allocated, watcher
    /// started, scan begun; the last one is selected and, when nothing runs anywhere, gets a shell.
    func addScopes(_ urls: [URL]) async {
        var added: [ScopeState] = []
        for url in urls {
            let path = ScopeDeclaration.normalizedPath(url.path)
            if let existing = config.scope(path: path) {
                selection = .scope(existing.id)
                continue
            }
            guard ScopeState.rootExists(URL(fileURLWithPath: path, isDirectory: true)) else {
                problems.error("\(url.lastPathComponent) is not a folder", detail: path)
                continue
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let slug = SlugAllocator.unique(base: slugify(name), taken: config.takenSlugs)
            let declaration = ScopeDeclaration(path: path, name: name, slug: slug)
            config.scopes.append(declaration)
            let state = ScopeState(declaration: declaration, git: env.git, problems: problems)
            scopes.append(state)
            added.append(state)
            state.startWatching()
        }
        guard !added.isEmpty else { return }
        saveConfig()
        for scope in added {
            Task { await scope.rescan() }
        }
        if let last = added.last {
            selection = .scope(last.id)
            if threads.isEmpty {
                await newThread(in: last.id)
            }
        }
    }

    func removeScope(_ id: ScopeID, closingThreads: Bool) async {
        guard let index = scopes.firstIndex(where: { $0.id == id }) else { return }
        let scope = scopes[index]
        scope.stopWatching()
        for session in threads(in: id) {
            await close(session.id, force: true)
        }
        for notice in exitNotices where notice.record.scopeID == id {
            await dismissExitNotice(notice.id)
        }
        for task in tasks where task.scopeID == id {
            task.stopWatching()
        }
        scopes.remove(at: index)
        config.scopes.removeAll { $0.id == id }
        saveConfig()
        for repo in scope.repos {
            let url = repo.url
            Task { await env.git.forget(url) }
        }
        if currentScopeID == id || scopeID(of: selection) == nil {
            currentScopeID = scopes.first?.id
            selection = scopes.first.map { .scope($0.id) }
        }
    }

    func refreshScope(_ id: ScopeID) {
        scope(id)?.refresh()
    }

    func setDiscoveryDepth(_ depth: Int, for id: ScopeID) {
        guard let scope = scope(id), let index = config.scopes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = ScopeDeclaration.clampDepth(depth)
        guard clamped != scope.declaration.discoveryDepth else { return }
        scope.declaration.discoveryDepth = clamped
        config.scopes[index].discoveryDepth = clamped
        saveConfig()
        scope.restartWatching()
        Task { await scope.rescan(full: true) }
    }

    func renameScope(_ id: ScopeID, name: String) {
        guard let scope = scope(id), let index = config.scopes.firstIndex(where: { $0.id == id }) else { return }
        scope.name = name
        config.scopes[index].name = name
        saveConfig()
    }

    func moveScopes(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        scopes.move(fromOffsets: offsets, toOffset: destination)
        config.scopes.move(fromOffsets: offsets, toOffset: destination)
        saveConfig()
    }

    /// The *Locate…* action of a missing scope: pick the folder again, keep the id and slug.
    private func locateScope(_ id: ScopeID) {
        Task {
            guard let scope = scope(id), let index = config.scopes.firstIndex(where: { $0.id == id }) else { return }
            let urls = await FolderPicker.chooseFolders()
            guard let url = urls.first else { return }
            let path = ScopeDeclaration.normalizedPath(url.path)
            scope.declaration.path = path
            config.scopes[index].path = path
            saveConfig()
            scope.restartWatching()
            await scope.rescan(full: true)
        }
    }

    // MARK: Threads

    private func register(_ session: ThreadSession) {
        session.onRecordChanged = { [weak self] record in
            // The exits a quit causes would clear `processAlive`; `terminateNow` wrote the records it needs already.
            guard let self, !self.isTerminating else { return }
            Task { await self.env.threadRecords.save(record) }
        }
        session.onExit = { [weak self] session, status in
            self?.threadExited(session, status: status)
        }
        threads.append(session)
        env.knownThreads.insert(session.id)
    }

    /// Opens a thread. `initialPrompt` is handed to the driver on this first launch only (the profile's
    /// `prompt` argv; ignored by profiles without one), never on a relaunch or resume.
    @discardableResult
    func newThread(in scopeID: ScopeID, driverID: String? = nil, cwdKind: ThreadCwdKind = .scopeRoot, taskID: TaskID? = nil,
                   title customTitle: String? = nil, initialPrompt: String? = nil,
                   origin: ThreadOrigin = .user) async -> ThreadSession? {
        guard let scope = scope(scopeID) else { return nil }
        let task = taskID.flatMap(task)
        guard scope.kind != .missing else {
            problems.warn("\(scope.name) is missing", detail: "Threads open once \(scope.url.path) is back.", scope: scopeID)
            return nil
        }
        guard let profile = profile(id: driverID) else {
            problems.error("No driver profile available", detail: "Add a JSON profile to \(ScopeHome.driversURL(home: env.home).path).",
                           actions: [.reveal(ScopeHome.driversURL(home: env.home).path)])
            return nil
        }
        let cwd: String
        switch cwdKind {
        case .scopeRoot:
            cwd = scope.url.path
        case .repoBase(let relativePath):
            cwd = relativePath.isEmpty ? scope.url.path : scope.url.appending(path: relativePath).path
        case .task:
            cwd = scope.url.path
        }
        var kind = cwdKind
        var title = scope.name
        var resolvedCwd = cwd
        if let task {
            guard ScopeState.rootExists(task.record.threadCwd) else {
                problems.error("Sandbox of \(task.name) is missing", detail: task.record.threadCwd.path, scope: scopeID)
                return nil
            }
            resolvedCwd = env.tasks.threadCwd(for: task.record).path
            kind = .task(slug: task.record.slug)
            title = task.name
        }
        if let customTitle { title = customTitle }
        let record = ThreadRecord(
            scopeID: scopeID,
            scopeRoot: scope.declaration.path,
            driverID: profile.id,
            title: title,
            cwd: resolvedCwd,
            cwdKind: kind,
            taskID: task?.id.rawValue,
            origin: origin
        )
        let session = ThreadSession(record: record, profile: profile)
        register(session)
        await env.threadRecords.save(record)
        // The next ⌘T in this scope opens the same driver.
        lastDriverByScope[scopeID] = profile.id
        selection = .thread(session.id)
        selectedThreadID = session.id
        await launch(session, mode: .launch, initialPrompt: initialPrompt)
        return session
    }

    func launch(_ session: ThreadSession, mode: LaunchMode, initialPrompt: String? = nil) async {
        guard !session.isAlive else { return }
        autoRelaunchBlocks[session.id] = nil
        guard let scope = scope(session.record.scopeID) else { return }
        if let taskID = task(of: session)?.id, let pending = setupRuns[taskID] {
            // An agent started before `pnpm install` finished works in a sandbox without its dependencies. The
            // thread exists (callers get its id at once) and starts when the setup is over, whatever its outcome.
            session.markLaunching()
            session.printNotice("waiting for the setup of the task")
            Task { [weak self] in
                await pending.run.value
                await self?.launch(session, mode: mode, initialPrompt: initialPrompt)
            }
            return
        }
        session.markLaunching()
        do {
            let plan = try await launcher.plan(record: session.record, profile: session.profile,
                                               scope: scope.declaration, task: task(of: session)?.record, mode: mode,
                                               initialPrompt: initialPrompt)
            session.launch(plan)
        } catch {
            session.fail(error)
            problems.report(error, thread: session.id, scope: scope.id)
        }
    }

    /// Relaunch picks the previous driver session back up when the thread has one — the profile's `resume`
    /// argv and a session id an adapter captured, which is exactly what an app restart leaves behind — and
    /// starts a fresh one otherwise. A session the driver no longer has ends in its own error, and the banner
    /// then offers Start Fresh.
    func relaunch(_ id: ThreadID) async {
        guard let session = session(id), !session.isAlive else { return }
        await launch(session, mode: .relaunch(profile: session.profile, resumeID: session.record.resumeID))
    }

    /// Start Fresh: a new driver session, leaving the previous one behind on purpose.
    func startFresh(_ id: ThreadID) async {
        guard let session = session(id), !session.isAlive else { return }
        await launch(session, mode: .launch)
    }

    func stop(_ id: ThreadID) {
        session(id)?.stop()
    }

    /// Closes a thread. With a running process and the preference on, asks first; returns `false` when cancelled.
    @discardableResult
    func close(_ id: ThreadID, force: Bool) async -> Bool {
        guard let session = session(id) else { return true }
        if session.isAlive {
            if !force, config.preferences.confirmCloseRunningThread {
                guard await confirmClose(session) else { return false }
            }
            closingThreads.insert(id)
            defer { closingThreads.remove(id) }
            session.stop()
            let deadline = ContinuousClock.now + .seconds(4)
            while session.isAlive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        takeExitNotice(id)
        let restoreSelection = selection
        detach(session)
        await forget(id: id, scopeID: session.record.scopeID, profile: session.profile)
        rememberClosed(ClosedThread(record: session.record, profile: session.profile, selection: restoreSelection))
        return true
    }

    // MARK: Undo close

    static let undoCloseWindow: Duration = .seconds(30)

    var canUndoCloseThread: Bool { !recentlyClosed.isEmpty }

    /// Keeps the record for `undoCloseWindow` so ⇧⌘T can bring the thread back.
    private func rememberClosed(_ closed: ClosedThread) {
        recentlyClosed.append(closed)
        undoTimers[closed.id]?.cancel()
        undoTimers[closed.id] = Task { [weak self] in
            try? await Task.sleep(for: AppModel.undoCloseWindow)
            guard !Task.isCancelled, let self else { return }
            self.recentlyClosed.removeAll { $0.id == closed.id }
            self.undoTimers[closed.id] = nil
        }
    }

    /// ⇧⌘T: reopens the most recently closed thread with the same record (resumed when the driver can).
    /// Synchronous for menu items and palette actions; the launch runs in its own task.
    func undoCloseThread() {
        guard let closed = recentlyClosed.popLast() else { return }
        Task { await restoreClosed(closed) }
    }

    private func restoreClosed(_ closed: ClosedThread) async {
        undoTimers[closed.id]?.cancel()
        undoTimers[closed.id] = nil
        guard scope(closed.record.scopeID) != nil, session(closed.id) == nil else { return }
        let session = ThreadSession(record: closed.record, profile: closed.profile)
        register(session)
        await env.threadRecords.save(closed.record)
        selection = .thread(closed.id)
        selectedThreadID = closed.id
        await launch(session, mode: session.canResume ? .resume : .launch)
    }

    /// Removes the tab (and the terminal view with it) and moves the selection to a neighbour or the
    /// scope's empty view. The record stays on disk.
    private func detach(_ session: ThreadSession) {
        let id = session.id
        let wasSelected = selectedThreadID == id
        let siblings = threadOrder(in: session.record.scopeID)
        let position = siblings.firstIndex { $0.id == id } ?? 0
        threads.removeAll { $0.id == id }
        if lastThreadByScope[session.record.scopeID] == id {
            lastThreadByScope[session.record.scopeID] = nil
        }
        guard wasSelected else { return }
        let remaining = threadOrder(in: session.record.scopeID)
        if let neighbour = remaining[safe: min(position, remaining.count - 1)] {
            selection = .thread(neighbour.id)
            selectedThreadID = neighbour.id
        } else if let taskID = session.record.taskID.flatMap(TaskID.init(rawValue:)), task(taskID) != nil {
            selection = .task(taskID)
            selectedThreadID = nil
        } else {
            selection = .scope(session.record.scopeID)
            selectedThreadID = nil
        }
    }

    /// The permanent part of a close: hook files, problems, the persisted record.
    private func forget(id: ThreadID, scopeID: ScopeID, profile: DriverProfile) async {
        env.knownThreads.remove(id)
        autoRelaunchBlocks[id] = nil
        AdapterInstaller.remove(profile: profile, threadID: id, home: env.home)
        problems.dismissAll(thread: id)
        await env.threadRecords.delete(id)
    }

    private func confirmClose(_ session: ThreadSession) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.title)”?"
        let pid = session.pid.map { " (pid \($0))" } ?? ""
        alert.informativeText = "The process\(pid) will be sent SIGHUP."
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    /// A live exit keeps the tab (greyed, ring dot) and shows a toast for 10 s (Relaunch / Details);
    /// the thread stays until the user closes it. With `autoCloseExitedThreads` the tab goes at once and
    /// the record is deleted when the toast goes. Exits caused by `close` or by quitting keep their own paths.
    private func threadExited(_ session: ThreadSession, status: ExitStatus) {
        dropDeliveries(for: session)
        if status.isExecFailure {
            problems.error("\(session.profile.name) could not be started (exit 127)",
                           detail: "Check the \"command\" of the \(session.profile.id) driver profile.",
                           scope: session.record.scopeID,
                           actions: [.reveal(ScopeHome.driversURL(home: env.home).path)])
        }
        notifier.clear(threadID: session.id)
        guard !isTerminating, !closingThreads.contains(session.id),
              threads.contains(where: { $0.id == session.id }) else { return }
        let autoClose = autoCloseExitedThreads
        if autoClose { detach(session) }
        let notice = ThreadExitNotice(record: session.record, profile: session.profile,
                                      status: status, lastTitle: session.terminalTitle, closesThread: autoClose)
        notice.onExpire = { [weak self] notice in
            Task { await self?.dismissExitNotice(notice.id) }
        }
        exitNotices.append(notice)
        notice.start()
    }

    /// Explicit dismiss or the 10 s countdown: the toast goes; the thread is closed for good only when the
    /// notice owns it (`autoCloseExitedThreads`).
    func dismissExitNotice(_ id: ThreadID) async {
        guard let notice = takeExitNotice(id) else { return }
        if notice.closesThread {
            await forget(id: id, scopeID: notice.record.scopeID, profile: notice.profile)
        }
    }

    /// The toast's *Close*: the thread goes for good (undoable for 30 s).
    func closeExitedThread(_ id: ThreadID) async {
        if session(id) != nil {
            await close(id, force: true)
        } else {
            await dismissExitNotice(id)
        }
    }

    /// Relaunches from the exit toast, in the same tab (or reopens the tab when it was auto-closed) — resuming
    /// the driver session like every other Relaunch.
    func relaunchExitNotice(_ id: ThreadID) async {
        guard let notice = takeExitNotice(id), scope(notice.record.scopeID) != nil else { return }
        let session: ThreadSession
        if let existing = self.session(id) {
            session = existing
        } else {
            session = ThreadSession(record: notice.record, profile: notice.profile)
            register(session)
        }
        selection = .thread(id)
        selectedThreadID = id
        await launch(session, mode: .relaunch(profile: session.profile, resumeID: session.record.resumeID))
    }

    /// Hovering a toast holds its countdown.
    func holdExitNotice(_ id: ThreadID, _ held: Bool) {
        guard let notice = exitNotices.first(where: { $0.id == id }) else { return }
        held ? notice.pause() : notice.start()
    }

    @discardableResult
    private func takeExitNotice(_ id: ThreadID) -> ThreadExitNotice? {
        guard let index = exitNotices.firstIndex(where: { $0.id == id }) else { return nil }
        let notice = exitNotices.remove(at: index)
        notice.cancel()
        return notice
    }

    // MARK: Tab navigation

    /// The sidebar's own order — each task's threads, in task order, then the scope-level threads. The
    /// sidebar is the only thread switcher, so ⌘1…⌘9, ⇧⌘[ / ⇧⌘] and the pick after a close all walk it.
    func threadOrder(in scope: ScopeID) -> [ThreadSession] {
        tasks(in: scope).flatMap { threads(in: $0.id) } + scopeLevelThreads(in: scope)
    }

    private var currentTabs: [ThreadSession] {
        currentScope.map { threadOrder(in: $0.id) } ?? []
    }

    func selectThread(index: Int) {
        let tabs = currentTabs
        guard tabs.indices.contains(index) else { return }
        selection = .thread(tabs[index].id)
        selectedThreadID = tabs[index].id
    }

    func selectNextThread() {
        step(by: 1)
    }

    func selectPreviousThread() {
        step(by: -1)
    }

    private func step(by delta: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedThreadID } ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % tabs.count + tabs.count) % tabs.count
        selectThread(index: next)
    }

    // MARK: Editor

    /// ⌘E: the thread's checkout (the sandbox for a task thread), else the selected repo, the selected
    /// task's checkout, or the scope root.
    func openInEditor(thread id: ThreadID?) {
        var path: String?
        if let id, let session = session(id) {
            path = session.reportedDirectory ?? session.record.cwd
        } else if case .repo(let scopeID, let relativePath) = selection, let scope = scope(scopeID) {
            path = scope.repo(relativePath: relativePath)?.url.path ?? scope.url.appending(path: relativePath).path
        } else if case .task(let id) = selection, let task = task(id) {
            path = task.record.threadCwd.path
        } else if let scope = currentScope {
            path = scope.url.path
        }
        guard let path else { return }
        openInEditor(path: path)
    }

    /// What ⌘E would open right now (for ⌥-click copy).
    var currentEditorPath: String? {
        if let session = currentThread { return session.reportedDirectory ?? session.record.cwd }
        if case .repo(let scopeID, let relativePath) = selection, let scope = scope(scopeID) {
            return scope.repo(relativePath: relativePath)?.url.path ?? scope.url.appending(path: relativePath).path
        }
        if let task = currentTask { return task.record.threadCwd.path }
        return currentScope?.url.path
    }

    /// ⌘⇧E: the task's `.code-workspace` when it exists, else its root folder.
    func openTaskInEditor(_ task: TaskState) {
        let workspace = task.record.workspaceURL
        if FileManager.default.fileExists(atPath: workspace.path) {
            openInEditor(path: task.record.rootURL.path, file: workspace.path)
        } else {
            openInEditor(path: task.record.threadCwd.path)
        }
    }

    /// Every "Open in Editor" affordance: ⌥-click copies the path instead (spec §7).
    func openInEditorOrCopy(path: String, file: String? = nil, line: Int? = nil) {
        if NSEvent.modifierFlags.contains(.option) {
            Pasteboard.copy(file ?? path)
            return
        }
        openInEditor(path: path, file: file, line: line)
    }

    /// Launches the configured editor on `path` (optionally at `file:line`).
    func openInEditor(path: String, file: String? = nil, line: Int? = nil) {
        guard let editor = config.preferences.editor else {
            problems.warn("No editor configured", detail: "Choose an editor in Settings.",
                          actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
            return
        }
        let searchPATH: String
        switch shellStatus {
        case .ready(let environment), .fallback(let environment):
            searchPATH = environment.path
        case .probing:
            searchPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        }
        do {
            try editor.launch(path: path, file: file, line: line, searchPATH: searchPATH)
        } catch {
            problems.error("Could not open the editor", detail: String(describing: error),
                           actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
        }
    }

    // MARK: Adapter events

    func handle(_ event: AdapterEvent) {
        guard let session = session(event.threadID), session.isAlive else { return }
        session.apply(event)
        notifyIfNeeded(event, session: session)
        flushDeliveries(for: session)
        acknowledgeShownResult()
    }

    // MARK: Problem actions

    private func perform(_ action: ProblemAction) {
        switch action.kind {
        case .retryLaunch(let id):
            Task { await relaunch(id) }
        case .reprobeShell:
            reprobeShell()
        case .openSettings:
            openSettings()
        case .revealFile(let path):
            Reveal.inFinder(URL(fileURLWithPath: path))
        case .rescan(let id):
            refreshScope(id)
        case .locateScope(let id):
            locateScope(id)
        case .rerunTaskSetup(let raw):
            if let id = TaskID(rawValue: raw), let task = task(id) {
                startSetup(for: task, runCommands: true)
            }
        case .dismiss:
            break
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Termination

    var runningThreadCount: Int {
        threads.filter(\.isAlive).count
    }

    func prepareForTermination() -> TerminationDecision {
        let running = runningThreadCount
        if running > 0, config.preferences.confirmQuitWithRunningThreads {
            return .askUser(running: running)
        }
        return .now
    }

    /// SIGHUP to every alive thread, then flush the stores. Records are already on disk.
    ///
    /// Each alive record is written once more, awaited, with `processAlive` still set, before anything is hung up:
    /// the exits that follow are not persisted (`register`), so these threads come back at the next launch however
    /// the quit and the saves interleave.
    func terminateNow() async {
        isTerminating = true
        for session in threads where session.isAlive {
            await env.threadRecords.save(session.record)
        }
        for session in threads where session.isAlive {
            session.stop(escalateAfter: 1.5)
        }
        env.uiState.flush()
        await env.config.flush()
        env.hooks?.stop()
        // Give the children a moment to hang up before the PTY masters close with the process.
        let deadline = ContinuousClock.now + .milliseconds(600)
        while runningThreadCount > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
