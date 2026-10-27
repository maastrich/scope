import AppKit
import Foundation
import ScopeAdapters
import ScopeControl
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
    private(set) var config: ScopeConfig = .empty {
        didSet {
            // The colour tokens read the theme as they are drawn, so it is set here, before any view that
            // observes the preferences redraws. The terminal keeps its own ground whatever the chrome.
            ChromePalette.theme = config.preferences.chromeTheme
        }
    }
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
    /// Which inspector sections are open, how they share the height, what the viewer shows.
    let inspector = InspectorModel()
    /// The shells of the tasks' shell panes (`AppModel+TaskShell`).
    let taskShells = TaskShellStore()
    /// The tabs of the tasks' Browser panes (`AppModel+Browser`).
    let browser = BrowserStore()
    /// Tokens Claude Code threads consumed (`AppModel+TokenUsage`).
    let tokenUsage = TokenUsageModel()
    /// The island under the notch (`AppModel+Island`).
    let island = IslandModel()
    /// What moved in a scope while the owner looked elsewhere (`AppModel+ReturnDigest`).
    let returnDigests = ReturnDigestModel()
    /// Messages waiting for a thread to finish its turn (`deliver`), per thread.
    var pendingDeliveries: [ThreadID: [PendingDelivery]] = [:]
    /// Scope the New Task sheet is open for (`nil` = closed).
    var newTaskScopeID: ScopeID?
    /// The scope whose settings sheet is up (its name, tile, context, repositories).
    var scopeSettingsID: ScopeID?
    /// The settings sheet was left through its *Open* graph button: the Graph sheet comes up once it is gone.
    @ObservationIgnored var graphFollowsScopeSettings = false
    private(set) var drivers = LoadedDrivers(profiles: [])
    private(set) var shellStatus: ShellStatus = .probing
    private(set) var isBootstrapped = false
    /// Follows Vibe Island's jump log (`AppModel+Attention`); `nil` until bootstrap.
    @ObservationIgnored var vibeIslandJumps: VibeIslandJumpWatcher?
    /// The watchers of the state documents under the home (`AppModel+ExternalChanges`); `nil` until bootstrap.
    @ObservationIgnored var stateWatchers: StateWatchers?
    /// Threads that exited live: the tab stays (greyed) while the toast shows; see `threadExited`.
    private(set) var exitNotices: [ThreadExitNotice] = []
    /// Closes and archives that can still be taken back (`AppModel+Undo`), and the toasts offering it.
    var undoLedger = UndoLedger<UndoableAction>(window: TimeInterval(AppModel.undoWindow.components.seconds))
    var undoNotices: [UndoNotice] = []
    /// Bumped when the undo ledger changes or a window runs out, so the menu bar's shortcuts follow the clock.
    var undoTick = 0

    /// Drives the sidebar highlight and, through `syncThreadFromSelection`, the scene: a thread row selects
    /// its tab, a task row its last thread, a scope or repo row shows the scope's empty view.
    var selection: SidebarItem? {
        didSet {
            guard !isRestoringUIState else { return }
            if selection != oldValue { noteSelectionClick() }
            if let scopeID = scopeID(of: selection), scopeID != currentScopeID {
                currentScopeID = scopeID
            }
            syncThreadFromSelection()
            persistUIState()
        }
    }

    /// The scope the sidebar shows (its tasks, threads and repositories). Follows the selection — selecting an
    /// item of another scope switches — and is remembered across launches; `nil` means "the first declared".
    ///
    /// Arriving in a scope brings what belongs to it and drops what belonged to the one left: its tasks' inspector
    /// sections come back, the sidebar filter and the scope-wide sheet go — a filter typed for one scope hid rows of
    /// the next, and the sheet was about the scope left behind.
    var currentScopeID: ScopeID? {
        didSet {
            guard !isRestoringUIState, currentScopeID != oldValue else { return }
            // A step that said which way it went (a swipe, ⌥⌘←/→) slides that way: with two scopes the other one is
            // both next and previous. Otherwise the ring's shorter way round, not the raw indices — the last scope to
            // the first is a step forwards.
            if let hint = scopeStepForward {
                scopeSwitchForward = hint
            } else if let old = oldValue, let new = currentScopeID {
                scopeSwitchForward = ScopeCycle.isForward(from: old, to: new, in: scopes.map(\.id))
            } else {
                scopeSwitchForward = true
            }
            if let id = currentScopeID { inspector.sections = places[id]?.sections ?? .defaults }
            searchUI.sidebarFilter = ""
            globalSheet = nil
            persistUIState()
            // The residents of a scope start on its first visit (`AutoRelaunchPlanner` starts the first scope's).
            if isBootstrapped, let id = currentScopeID { startResidents(in: id) }
            if isBootstrapped { scopeSwitched(from: oldValue, to: currentScopeID) }
        }
    }

    /// Whether the last scope switch went towards a later scope: the side the sidebar's content slides in from.
    private(set) var scopeSwitchForward = true

    /// The direction of the ring step being taken by `selectAdjacentScope`, for `currentScopeID` to slide by.
    @ObservationIgnored private var scopeStepForward: Bool?

    /// The scope a swipe in progress is dragging towards, for the header to light its tile. Transient: never saved.
    private(set) var swipeTargetID: ScopeID?

    func setSwipeTarget(_ id: ScopeID?) {
        // A swipe reports every trackpad event; only a change of side is worth redrawing the header for.
        if swipeTargetID != id { swipeTargetID = id }
    }

    /// Where the user was in each scope (`ScopePlace`), kept current by `persistUIState` and read by `selectScope`.
    private(set) var places: [ScopeID: ScopePlace] = [:]

    /// Driver last opened per scope (restored from the UI state): what ⌘T reaches for first.
    var lastDriverByScope: [ScopeID: String] = [:]
    /// The Graph sheet's view and folded groups, per scope (`UIState.graphPlaces`).
    var graphPlaces: [ScopeID: GraphPlace] = [:] {
        didSet { if !isRestoringUIState, graphPlaces != oldValue { persistUIState() } }
    }

    /// Drives the scene. Kept in sync with `selection`.
    var selectedThreadID: ThreadID? {
        didSet {
            if let id = selectedThreadID, let session = session(id) {
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

    /// The scope-wide sheet over the window, if one is up. Never persisted: a sheet is a look, not a layout.
    var globalSheet: GlobalSheet?
    /// The family of attempts the Compare sheet shows (`TaskAttempt.group`), while `globalSheet` is `.compareAttempts`.
    var attemptsCompared: String?

    /// Shows a task's panel in the inspector (⌘D, ⇧⌘B, the task's menu, a notification).
    func showInspector(_ tab: InspectorTab) {
        revealSection(tab.section)
    }

    /// Opens the Graph sheet (the sidebar button, ⌥⌘G, the palette, a repo's "See Graph").
    func presentGraph() {
        globalSheet = .graph
    }

    /// Width of the sidebar column in points (200…420).
    var sidebarWidth: Double = UIState.defaultSidebarWidth {
        didSet { if !isRestoringUIState, sidebarWidth != oldValue { persistUIState() } }
    }

    /// The sidebar column is on screen (⌃⌘S). Not saved: a launch starts with the sidebar, which is the only way
    /// to a thread.
    var sidebarShown = true

    /// ⌃⌘S. While a thread is maximized the sidebar is hidden rather than off, so the toggle means "show it" and
    /// gives the layout back.
    func toggleSidebar() {
        if threadMaximized {
            threadMaximized = false
            sidebarShown = true
        } else {
            sidebarShown.toggle()
        }
    }

    /// Width of the inspector column in points (320…520).
    var inspectorWidth: Double = UIState.defaultInspectorWidth {
        didSet { if !isRestoringUIState, inspectorWidth != oldValue { persistUIState() } }
    }

    /// Exited threads close themselves when their toast goes (Settings ▸ General).
    var autoCloseExitedThreads: Bool {
        config.preferences.autoCloseExitedThreads
    }

    @ObservationIgnored private lazy var logos = ScopeLogoStore(folder: ScopeHome.scopeLogosURL(home: env.home))
    /// Drops expired undo entries, so the Edit menu follows the window without being asked.
    @ObservationIgnored var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var isRestoringUIState = false
    @ObservationIgnored private var reportedShellWarning = false
    @ObservationIgnored var launcher: ThreadLauncher
    /// Threads being closed by the user (`close`) or by termination: their exit is not a live exit.
    @ObservationIgnored private var closingThreads: Set<ThreadID> = []
    @ObservationIgnored private(set) var isTerminating = false
    /// Threads that were running when the app went down and stayed stopped at launch for a reason the user did not
    /// choose; the banner says which. Cleared by the thread's next launch.
    var autoRelaunchBlocks: [ThreadID: AutoRelaunchSkip] = [:]
    /// Setups in flight, per task: a thread of the task waits for its task's entry before it launches. The token
    /// tells a finished run it is still the latest one before it removes itself.
    @ObservationIgnored var setupRuns: [TaskID: (token: UUID, run: Task<Void, Never>)] = [:]
    /// The 30-minute garbage collection loop (`startGarbageCollection`).
    @ObservationIgnored var garbageCollector: Task<Void, Never>?
    /// The checkpoint waiting to be taken for a task, after a turn ended (`AppModel+Checkpoints`); a turn ending in
    /// the meantime replaces it.
    @ObservationIgnored var checkpointJobs: [TaskID: Task<Void, Never>] = [:]
    /// The turns read out of each thread's transcript for the reading column (`AppModel+Reading`), and the reads
    /// in flight. `nil` means never read; an empty list, read and found nothing.
    @ObservationIgnored var replyHistory: [ThreadID: [TranscriptTurn]] = [:]
    @ObservationIgnored var replyHistoryUnavailable: Set<ThreadID> = []
    @ObservationIgnored var replyHistoryJobs: [ThreadID: Task<Void, Never>] = [:]
    /// The background pull request refresh (`startPullRequestRefresh`) and when each task is next due.
    @ObservationIgnored var pullRequestRefresher: Task<Void, Never>?
    /// Follows the Claude Code transcripts (`AppModel+ClaudeSession`).
    @ObservationIgnored var claudeTranscriptReader: Task<Void, Never>?
    /// A task's pull requests asked about again because one of its threads reported one (`AppModel+ClaudeSession`).
    @ObservationIgnored var claudePullRequestRefreshes: [TaskID: Task<Void, Never>] = [:]
    /// Pull requests a transcript reported before this launch are history, not news: no `gh` call for them.
    @ObservationIgnored let claudeSessionWatchStart = Date.now
    /// The loop behind `AppModel+Ports`.
    @ObservationIgnored var portScanner: Task<Void, Never>?
    /// The tasks whose Environment card is open — their listening processes are read with the ports — and the `lsof`
    /// runs in flight, per task.
    @ObservationIgnored var processWatchers: Set<TaskID> = []
    @ObservationIgnored var processRuns: [TaskID: Task<Void, Never>] = [:]
    /// The loop behind `AppModel+DiskUsage`, and the one-off measurements in flight, per task.
    @ObservationIgnored var diskUsageRefresher: Task<Void, Never>?
    @ObservationIgnored var diskUsageRuns: [TaskID: Task<Void, Never>] = [:]
    @ObservationIgnored var pullRequestSchedule = PullRequestRefreshSchedule()
    /// The minute loop behind `AppModel+Schedules`, when it started watching, and the schedules whose run is in flight.
    @ObservationIgnored var scheduler: Task<Void, Never>?
    @ObservationIgnored var scheduleWatchedSince = Date.now
    @ObservationIgnored var runningSchedules: Set<String> = []
    /// Resident threads Scope will not start again on its own, and why (`ResidentHold`). Cleared by the next launch.
    var residentHolds: [ThreadID: ResidentHold] = [:]
    /// Resident threads whose process died and that are about to start again; the banner says so.
    var residentRestarts: [ThreadID: Task<Void, Never>] = [:]
    /// Quick exits in a row per resident thread (`ResidentRestart`).
    @ObservationIgnored var residentQuickExits: [ThreadID: Int] = [:]
    /// Threads the user or an agent asked to stop: their exit is not a crash, and a resident one stays stopped.
    @ObservationIgnored var stopRequests: Set<ThreadID> = []

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

    /// The scope switcher: goes back to where the user was in `id` — the row, the thread on screen, the tab — or,
    /// on a first visit, to its first thread. Asked for the scope already shown, it selects the scope's own row.
    func selectScope(_ id: ScopeID) {
        guard scope(id) != nil else { return }
        guard id != currentScope?.id else {
            selection = .scope(id)
            return
        }
        let place = places[id]
        // The scope's own row is where a scope with no thread leaves you, not somewhere you chose to be: once the
        // scope has threads it is treated as a first visit, or an agent's work would hide behind an empty view.
        let wasNowhere = place?.selection == .scope(id) && !threadOrder(in: id).isEmpty
        if let item = place?.selection, isSelectable(item, in: id), !wasNowhere {
            selection = item
            // A task row stands for one of its threads: the one that was being read, not the first.
            if case .task(let taskID) = item, let thread = place?.thread, session(thread)?.record.taskID == taskID.rawValue {
                selectedThreadID = thread
            }
        } else if let first = threadOrder(in: id).first {
            selection = .thread(first.id)
            selectedThreadID = first.id
        } else {
            selection = .scope(id)
        }
    }

    /// Whether a remembered sidebar item still names a row of `scopeID`.
    private func isSelectable(_ item: SidebarItem, in scopeID: ScopeID) -> Bool {
        switch item {
        case .scope(let id): id == scopeID
        case .repo(let id, let relativePath): id == scopeID && scope(id)?.repo(relativePath: relativePath) != nil
        case .thread(let id): session(id)?.record.scopeID == scopeID
        case .task(let id): task(id).map { $0.scopeID == scopeID && !$0.isArchived } ?? false
        }
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

    /// Threads whose cwd is not a task sandbox (scope root or a base), the resident ones aside: the loose threads.
    func scopeLevelThreads(in scope: ScopeID) -> [ThreadSession] {
        threads.filter { $0.record.scopeID == scope && $0.record.taskID == nil && $0.record.resident == nil }
    }

    /// The orchestrator and the terminal Scope keeps in `scope`, in that order.
    func residents(in scope: ScopeID) -> [ThreadSession] {
        ResidentRole.allCases.compactMap { resident($0, in: scope) }
    }

    func resident(_ role: ResidentRole, in scope: ScopeID) -> ThreadSession? {
        threads.first { $0.record.scopeID == scope && $0.record.resident == role }
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

    /// Whether something just opened takes the sidebar selection. What the user opened does. What an agent opened
    /// (`scope thread new`, `scope_task_new`) would replace the terminal being read, move the inspector to another
    /// subject and, for another scope, switch the sidebar — so it only does as far as `Preferences.agentOpenedFocus`
    /// says; the row and its state mark say it is there either way.
    func takesSelection(_ origin: ThreadOrigin, in scopeID: ScopeID) -> Bool {
        origin.author == .user || config.preferences.agentOpenedFocus
            .takesSelection(threadShown: currentThread != nil, sameScope: currentScope?.id == scopeID)
    }

    /// ⌘T: a thread in `newThreadTarget` with the default driver (or `driverID`, on `model`).
    @discardableResult
    func newThreadInCurrentContext(driverID: String? = nil, model: String? = nil) async -> ThreadSession? {
        await newThread(at: newThreadTarget, driverID: driverID, model: model)
    }

    /// The sidebar's New Thread button: a loose thread (`looseThreadTarget`), never one inside a task.
    @discardableResult
    func newLooseThread(driverID: String? = nil) async -> ThreadSession? {
        await newThread(at: looseThreadTarget, driverID: driverID, model: nil)
    }

    private func newThread(at target: NewThreadTarget?, driverID: String?, model: String?) async -> ThreadSession? {
        switch target {
        case .scopeRoot(let scope):
            return await newThread(in: scope.id, driverID: driverID, model: model)
        case .repoBase(let scope, let relativePath):
            return await newThread(in: scope.id, driverID: driverID, cwdKind: .repoBase(relativePath: relativePath), model: model)
        case .task(let task):
            return await newThread(in: task.scopeID, driverID: driverID, taskID: task.id, model: model)
        case nil:
            return nil
        }
    }

    /// The model a thread of `profile` opens on in `scope` when `requested` is what the caller said (`ModelChoice`):
    /// the request, then the scope's default, then the driver's from Settings. Nothing for a driver that takes none.
    func resolvedModel(_ requested: String?, profile: DriverProfile, in scope: ScopeState) -> String? {
        guard profile.acceptsModel else { return nil }
        return ModelChoice.resolve(requested: requested, scopeDefault: scope.declaration.model,
                                   driverDefault: config.preferences.driverModels[profile.id])
    }

    /// "Other Model…": an alert with a text field, `nil` when cancelled or left empty.
    func promptModelName(for profile: DriverProfile) -> String? {
        let alert = NSAlert()
        alert.messageText = "Model for \(profile.name)"
        alert.informativeText = "Passed to the driver as \((profile.modelArgs ?? []).joined(separator: " ")). "
            + "The thread keeps it across relaunches."
        alert.addButton(withTitle: "Open Thread")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = profile.knownModels.first ?? "model name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// The profile for an id, else `defaultProfile`: what everything but the user's own ⌘T opens.
    func profile(id: String?) -> DriverProfile? {
        if let id, let profile = drivers.profile(id: id) { return profile }
        return defaultProfile
    }

    /// The driver a thread gets when nothing names one and the user did not ask for it in the app (an agent, the
    /// CLI, the MCP server, a schedule, an attempt, follow-main, the graph): Settings ▸ Default driver, else the
    /// first agent profile installed (`DriverChoice`). Never the driver last opened in a scope — that one is the
    /// UI's shortcut, and it used to leak into every task an agent created.
    var defaultProfile: DriverProfile? {
        DriverChoice.resolve(preference: config.preferences.defaultDriverID, profiles: drivers.profiles)
    }

    /// The driver the user's ⌘T opens in `scopeID`: the preference when set, else the one last opened in the scope,
    /// else the first agent profile. Reaching for the last one is what makes an *automatic* ⌘T stop asking: a scope
    /// you drive with Claude Code keeps giving you Claude Code, and the shell is a choice you make rather than the
    /// one you are given. A preference set in Settings wins over that memory.
    func preferredProfile(in scopeID: ScopeID) -> DriverProfile? {
        DriverChoice.resolve(preference: config.preferences.defaultDriverID, lastOpened: lastDriverByScope[scopeID],
                             profiles: drivers.profiles)
    }

    /// `preferredProfile(in:)` for the scope being shown: what the empty scene and the new-task sheet offer first.
    var preferredProfile: DriverProfile? {
        guard let scope = currentScopeID else { return defaultProfile }
        return preferredProfile(in: scope)
    }

    /// Id of `preferredProfile`, for the views that pass a driver id around.
    var preferredDriverID: String? { preferredProfile?.id }

    // MARK: Bootstrap

    /// §(d).5: stores in parallel, scopes built and scanned, records rebound, UI state restored.
    func bootstrap() async {
        startBadgeTracking()
        guard !isBootstrapped else { return }
        let skipAutoRelaunch = AppServices.shiftHeldAtLaunch || NSEvent.modifierFlags.contains(.shift)
        // First, so the session marker is open before anything can go wrong; read back by `journalStart`.
        let previousSession = await env.journal.beginSession(version: env.appVersion)
        problems.scopeSlug = { [weak self] id in self?.scope(id)?.declaration.slug }
        startActivationTracking()
        let refreshed = SkillInstaller(userHome: FileManager.default.homeDirectoryForCurrentUser,
                                       debug: BuildFlavor.isDebug).refreshOutdated()
        if !refreshed.isEmpty {
            Log.app.info("rewrote the outdated Scope skill for \(refreshed.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }

        // Kicked off, not awaited: the probe can take seconds on a slow rc file.
        startShellProbe()
        startTokenMeter()
        startClaudeTranscriptReader()
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
        startUsage()
        startAssist()
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
            problems.error(ProblemTitle(verbatim: error.title), detail: error.detail)
        }

        drivers = await driverTask.value
        refreshAssistModels()
        reportDriverProblems()

        scopes = config.scopes.map { ScopeState(declaration: $0, git: env.git, problems: problems) }
        for scope in scopes {
            scope.startWatching()
            Task { await scope.rescan() }
        }
        tidyScopeLogos(sweeping: configProblem == nil)

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
            // A resident is given the driver its role calls for (`reconcileResidents`): nothing to warn about.
            if profile?.id != record.driverID, record.resident == nil {
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
        // After the restore and before the relaunch: a scope declared before residents existed gets its two here.
        await reconcileResidents()
        env.knownThreads.replaceAll(Set(threads.map(\.id)))

        restoreUIState()
        await finishInterruptedPutBacks()
        await autoRelaunchThreads(orphans: restore.orphans, skippedOnce: skipAutoRelaunch)
        startFollowingVibeIsland()
        startGarbageCollection()
        startPullRequestRefresh()
        startSchedules()
        startPortScanning()
        startDiskUsageRefresh()
        isBootstrapped = true
        startReturnTracking()
        startWatchingState()
        startIsland()
        journalStart(previous: previousSession, threads: threads.count, skippedRelaunch: skipAutoRelaunch)
        // Written now, not at the next tick: a launch that dies in its first seconds is exactly the one to see.
        Task { [env] in await env.journal.flush() }
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
                SubprocessEnvironment.install(SubprocessEnvironment.compose(resolved.variables, source: .probed))
            case .pathHelper, .processEnvironment:
                shellStatus = .fallback(resolved)
                SubprocessEnvironment.install(SubprocessEnvironment.compose(resolved.variables, source: .fallback))
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
        inspector.weights = state.inspectorWeights
        inspector.viewerShare = ColumnLayout.clampViewerShare(state.viewerShare)
        places = state.places.filter { scope($0.key) != nil }
        base.pins = state.basePins.filter { isLiveBaseContext($0.key) }
        inspectorWidth = ColumnLayout.clampInspectorWidth(state.inspectorWidth)
        sidebarWidth = ColumnLayout.clampSidebarWidth(state.sidebarWidth)
        lastDriverByScope = state.lastDrivers
        graphPlaces = state.graphPlaces
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
        if let id = currentScopeID { inspector.sections = places[id]?.sections ?? .defaults }
        if selection == nil, let scope = currentScope {
            if let first = threads(in: scope.id).first {
                selection = .thread(first.id)
                selectedThreadID = first.id
            } else {
                selection = .scope(scope.id)
            }
        }
    }

    func persistUIState() {
        if let id = currentScope?.id {
            places[id] = ScopePlace(selection: selection, thread: selectedThreadID, sections: inspector.sections)
        }
        var state = UIState()
        state.selectedItem = selection
        state.selectedThread = selectedThreadID
        state.currentScope = currentScopeID
        state.reposShown = Set(scopes.filter(\.reposShown).map(\.id))
        state.looseThreadsCollapsed = Set(scopes.filter { !$0.looseThreadsShown }.map(\.id))
        state.inspectorVisible = inspectorShown
        state.inspectorWeights = inspector.weights
        state.viewerShare = inspector.viewerShare
        state.basePins = base.pins
        state.places = places
        state.inspectorWidth = inspectorWidth
        state.sidebarWidth = sidebarWidth
        state.lastDrivers = lastDriverByScope
        state.graphPlaces = graphPlaces
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

    /// The config as somebody changed it on disk (`applyExternalConfig`): taken as is, never written back.
    func takeConfig(fromDisk config: ScopeConfig) {
        self.config = config
    }

    /// A scope declared on disk behind the app (`applyExternalConfig`): shown and watched, nothing written.
    func addScope(fromDisk declaration: ScopeDeclaration) -> ScopeState {
        let state = ScopeState(declaration: declaration, git: env.git, problems: problems)
        scopes.append(state)
        state.startWatching()
        return state
    }

    /// The sidebar order as `config.scopes` on disk has it; a scope the order does not name goes last.
    func orderScopes(like declarations: [ScopeDeclaration]) {
        let order = Dictionary(uniqueKeysWithValues: declarations.enumerated().map { ($1.id, $0) })
        scopes.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private func saveConfig() {
        let config = config
        Task { await env.config.save(config) }
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        let before = config.preferences
        change(&config.preferences)
        guard config.preferences != before else { return }
        noteSettingsChanged(from: before)
        saveConfig()
        if config.preferences.shellProbe != before.shellProbe {
            reprobeShell()
        }
        if config.preferences.assist != before.assist { refreshAssistModels() }
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
        await reconcileResidents()
        if let last = added.last, let orchestrator = residents(in: last.id).first {
            // A new scope opens on its orchestrator, running: the thing to talk to about it.
            selection = .thread(orchestrator.id)
            selectedThreadID = orchestrator.id
            startResidents(in: last.id)
        } else if let last = added.last {
            selection = .scope(last.id)
        }
    }

    func removeScope(_ id: ScopeID, closingThreads: Bool) async {
        guard scopes.contains(where: { $0.id == id }) else { return }
        config.scopes.removeAll { $0.id == id }
        saveConfig()
        await tearDownScope(id)
    }

    /// Everything `removeScope` does besides the config: the state, its threads and its tasks' watchers go, the
    /// selection moves on. Also the path of a scope whose declaration vanished from `config.json` on disk.
    func tearDownScope(_ id: ScopeID) async {
        guard let index = scopes.firstIndex(where: { $0.id == id }) else { return }
        let scope = scopes[index]
        scope.stopWatching()
        // The one way a resident thread goes: its scope goes with it.
        for session in threads(in: id) {
            await close(session.id, force: true, evenResident: true, undoable: false)
        }
        for notice in exitNotices where notice.record.scopeID == id {
            await dismissExitNotice(notice.id)
        }
        for task in tasks where task.scopeID == id {
            task.stopWatching()
        }
        scopes.remove(at: index)
        for name in [scope.declaration.logo, scope.declaration.logoDark].compactMap(\.self) { logos.remove(named: name) }
        if scopeSettingsID == id { scopeSettingsID = nil }
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

    // MARK: Scope identity

    /// The most pressing thing happening in `scope`: the mark on its tile, and what orders the tiles.
    func activity(of scope: ScopeState) -> ScopeActivity {
        ScopeActivity(threads: threads(in: scope.id).map(\.displayState), missing: scope.kind == .missing)
    }

    /// The other scopes in ring order (`ScopeCycle.rotated`), starting with the one a swipe to the next goes to.
    func scopeTiles(besides current: ScopeState) -> ScopeTiles {
        let ring = ScopeCycle.rotated(scopes.map(\.id), after: current.id).compactMap(scope)
        return ScopeTiles(ring: ring.map { (scope: $0, activity: activity(of: $0)) },
                          order: config.preferences.scopeTileOrder)
    }

    /// Changes what the owner chose for a scope (icon, tint, images, context) and saves it.
    func updateScopeIdentity(_ id: ScopeID, _ change: (inout ScopeDeclaration) -> Void) {
        guard let scope = scope(id), let index = config.scopes.firstIndex(where: { $0.id == id }) else { return }
        change(&config.scopes[index])
        scope.declaration = config.scopes[index]
        saveConfig()
    }

    /// The image of the scope's tile in an appearance; `nil` without one or when the file is gone.
    func scopeLogo(_ scope: ScopeState, dark: Bool) -> ScopeLogoStore.Logo? {
        scope.declaration.logo(dark: dark).flatMap(logos.logo(named:))
    }

    /// Imports `source` under the home as one of the scope's images. The copy is what the app reads from then
    /// on: nothing is written in the scope's folder and the original may move. Throws what makes the image
    /// unusable (`ScopeLogo.Failure`), for the caller to say where the user is looking.
    func setScopeLogo(_ id: ScopeID, _ slot: ScopeLogoSlot = .standard, from source: ScopeLogoSource,
                      enforcingShape: Bool = true) throws {
        guard let scope = scope(id) else { return }
        let name = try logos.save(source, slug: scope.declaration.slug, enforcingShape: enforcingShape)
        if let old = scope.declaration[keyPath: slot.keyPath] { logos.remove(named: old) }
        updateScopeIdentity(id) { $0[keyPath: slot.keyPath] = name }
    }

    func removeScopeLogo(_ id: ScopeID, _ slot: ScopeLogoSlot = .standard) {
        guard let scope = scope(id), let name = scope.declaration[keyPath: slot.keyPath] else { return }
        logos.remove(named: name)
        updateScopeIdentity(id) { $0[keyPath: slot.keyPath] = nil }
    }

    /// At launch: brings the copies v0.14.0 made (the file as it was picked, at full size) to the stored form, and
    /// deletes the files no scope names. An image is never taken away here: one that cannot be converted stays
    /// as it is and is still shown, and nothing is swept when the config did not load — every file would look
    /// orphaned, and the backup that names them could no longer be restored.
    private func tidyScopeLogos(sweeping: Bool) {
        for scope in scopes {
            for slot in [ScopeLogoSlot.standard, .dark] {
                guard let name = scope.declaration[keyPath: slot.keyPath], let data = logos.data(named: name),
                      !ScopeLogo.isNormalized(data) else { continue }
                do {
                    try setScopeLogo(scope.id, slot, from: .data(data), enforcingShape: false)
                } catch {
                    Log.app.warning("scope image \(name, privacy: .public) left as it is: \(String(describing: error), privacy: .public)")
                }
            }
        }
        guard sweeping else { return }
        logos.sweep(keeping: Set(config.scopes.flatMap { [$0.logo, $0.logoDark].compactMap(\.self) }))
    }

    /// Saves what the owner wrote about a scope and rewrites the context file of its tasks, so agents already at
    /// work read it on their next turn.
    /// The scope's default model (`ScopeDeclaration.model`); blank clears it.
    func setScopeModel(_ id: ScopeID, _ text: String) {
        guard let scope = scope(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (scope.declaration.model ?? "") != trimmed else { return }
        updateScopeIdentity(id) { $0.model = trimmed.isEmpty ? nil : trimmed }
    }

    func setScopeContext(_ id: ScopeID, _ text: String) {
        guard let scope = scope(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (scope.declaration.context ?? "") != trimmed else { return }
        updateScopeIdentity(id) { $0.context = trimmed.isEmpty ? nil : trimmed }
        Task { await refreshContextFiles(of: scope) }
    }

    /// Drops the scope `id` at the place of `target` in the declared order (a tile dragged onto another).
    func moveScope(_ id: ScopeID, onto target: ScopeID) {
        guard id != target, let from = scopes.firstIndex(where: { $0.id == id }),
              let to = scopes.firstIndex(where: { $0.id == target }) else { return }
        moveScopes(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
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
            if currentScopeID == id { startResidents(in: id) }
        }
    }

    // MARK: Threads

    func register(_ session: ThreadSession, activity: ThreadActivity? = nil) {
        wire(session, activity: activity)
        threads.append(session)
        env.knownThreads.insert(session.id)
    }

    /// Puts `new` in the place of `old`, which has the same id and is not running: a resident thread changing driver.
    func replace(_ old: ThreadSession, with new: ThreadSession) {
        guard let index = threads.firstIndex(where: { $0 === old }), !old.isAlive else { return }
        old.onRecordChanged = nil
        old.onExit = nil
        old.onActivityChanged = nil
        old.onClaudePullRequests = nil
        wire(new, activity: old.activity)
        threads[index] = new
    }

    private func wire(_ session: ThreadSession, activity: ThreadActivity?) {
        wireActivity(session, carrying: activity)
        wireClaudeSession(session)
        session.onRecordChanged = { [weak self] record in
            // The exits a quit causes would clear `processAlive`; `terminateNow` wrote the records it needs already.
            guard let self, !self.isTerminating else { return }
            Task { await self.env.threadRecords.save(record) }
        }
        session.onExit = { [weak self] session, status in
            self?.threadExited(session, status: status)
        }
        session.onOpenLink = { [weak self] session, link in
            guard let self else { return false }
            return self.openFileLink(link, from: session)
                || self.openWebLink(link, task: session.record.taskID.flatMap { TaskID(rawValue: $0) }.flatMap(self.task))
        }
    }

    /// Opens a thread. `initialPrompt` is handed to the driver on this first launch only (the profile's
    /// `prompt` argv; ignored by profiles without one), never on a relaunch or resume. `model` is what the caller
    /// asked for, settled against the scope's and the driver's defaults (`resolvedModel`) and kept on the record.
    @discardableResult
    /// `branch`, with a task: the thread starts in the task's worktree on that branch (`TaskRecord.sandboxes(onBranch:)`)
    /// instead of the task's usual directory.
    func newThread(in scopeID: ScopeID, driverID: String? = nil, cwdKind: ThreadCwdKind = .scopeRoot, taskID: TaskID? = nil,
                   title customTitle: String? = nil, initialPrompt: String? = nil,
                   origin: ThreadOrigin = .user, model: String? = nil, branch: String? = nil) async -> ThreadSession? {
        guard let scope = scope(scopeID) else { return nil }
        let task = taskID.flatMap(task)
        guard scope.kind != .missing else {
            problems.warn("\(scope.name) is missing", detail: "Threads open once \(scope.url.path) is back.", scope: scopeID)
            return nil
        }
        // The user's own ⌘T may fall back on the driver last opened here; anything else gets the Settings default.
        let fallback = origin.author == .user ? preferredProfile(in: scopeID) : defaultProfile
        guard let profile = driverID.flatMap({ drivers.profile(id: $0) }) ?? fallback else {
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
            var directory = env.tasks.threadCwd(for: task.record)
            if let branch {
                guard let worktree = task.record.sandboxes(onBranch: branch).first else {
                    problems.error("\(task.name) has no worktree on \(branch)", detail: "Add one first: scope task branch add \(task.record.slug) \(branch).", scope: scopeID)
                    return nil
                }
                directory = worktree.sandboxURL
            }
            guard ScopeState.rootExists(directory) else {
                problems.error("Sandbox of \(task.name) is missing", detail: directory.path, scope: scopeID)
                return nil
            }
            resolvedCwd = directory.path
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
            origin: origin,
            model: resolvedModel(model, profile: profile, in: scope)
        )
        let session = ThreadSession(record: record, profile: profile)
        register(session)
        await env.threadRecords.save(record)
        // The next ⌘T in this scope opens the same driver.
        lastDriverByScope[scopeID] = profile.id
        if takesSelection(origin, in: scopeID) {
            selection = .thread(session.id)
            selectedThreadID = session.id
        }
        await launch(session, mode: .launch, initialPrompt: initialPrompt)
        return session
    }

    func launch(_ session: ThreadSession, mode: LaunchMode, initialPrompt: String? = nil) async {
        guard !session.isAlive else { return }
        autoRelaunchBlocks[session.id] = nil
        // Any start, asked for or automatic, ends a resident's hold and replaces a restart still waiting.
        residentHolds[session.id] = nil
        residentRestarts.removeValue(forKey: session.id)?.cancel()
        stopRequests.remove(session.id)
        guard let scope = scope(session.record.scopeID) else { return }
        if let initialPrompt, !initialPrompt.isEmpty { session.expectTurn() }
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
                                               initialPrompt: initialPrompt,
                                               claudeUsesTerminalPalette: config.preferences.claudeUsesTerminalPalette,
                                               readLimits: config.preferences.showTokenMeter)
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
        guard let found = session(id), !found.isAlive else { return }
        let session = conformResident(found)
        await launch(session, mode: .relaunch(profile: session.profile, resumeID: session.record.resumeID))
    }

    /// Start Fresh: a new driver session, leaving the previous one behind on purpose.
    func startFresh(_ id: ThreadID) async {
        guard let found = session(id), !found.isAlive else { return }
        await launch(conformResident(found), mode: .launch)
    }

    /// Stop (⌘.), from the user or an agent. A resident thread stays stopped afterwards, until Relaunch or the next app
    /// launch: a thread that cannot be stopped when it misbehaves would be worse than one that can be closed.
    func stop(_ id: ThreadID) {
        guard let session = session(id) else { return }
        if session.isAlive { stopRequests.insert(id) }
        residentRestarts.removeValue(forKey: id)?.cancel()
        session.stop()
    }

    /// Closes a thread. With something to lose (`CloseGuard.threadRisks`: an agent mid-turn, a shell with a live
    /// process) and the preference on, asks first; returns `false` when cancelled. Whatever asked, the thread can be
    /// reopened for `undoWindow` (`AppModel+Undo`). A resident thread is never closed — it is stopped at most —
    /// except when its scope is removed (`evenResident`).
    @discardableResult
    func close(_ id: ThreadID, force: Bool, evenResident: Bool = false, by requester: CloseRequester = .user,
               undoable: Bool = true) async -> Bool {
        guard let session = session(id) else { return true }
        guard evenResident || session.record.resident == nil else {
            NSSound.beep()
            return false
        }
        residentRestarts.removeValue(forKey: id)?.cancel()
        residentHolds[id] = nil
        residentQuickExits[id] = nil
        if session.isAlive {
            let risks = CloseGuard.threadRisks(isAlive: true, isWorking: session.isWorking, reportsActivity: session.deliversEvents)
            if !force, CloseGuard.shouldConfirm(risks, preference: config.preferences.confirmCloseRunningThread) {
                guard await confirmClose(session, risks: risks) else { return false }
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
        // A process that outlived the wait still exits later, and its closing turn would write the file back.
        session.onActivityChanged = nil
        session.onClaudePullRequests = nil
        await keepTimeline(of: session.record, activity: session.activity)
        await forget(id: id, scopeID: session.record.scopeID, profile: session.profile)
        // A thread hung up by its task's archive or close comes back with the task, not on its own: its worktree is gone.
        if undoable {
            remember(.closedThread(ClosedThread(record: session.record, profile: session.profile, activity: session.activity,
                                                selection: restoreSelection)), by: requester)
        }
        return true
    }

    /// Removes the tab (and the terminal view with it) and moves the selection to a neighbour of the same group —
    /// the other threads of its task, or the other loose threads — else to the task row, else to the scope's empty
    /// view. Never into another task: closing a thread is not asking to look at different work. The record stays
    /// on disk.
    private func detach(_ session: ThreadSession) {
        let id = session.id
        let wasSelected = selectedThreadID == id
        let sameGroup: (ThreadSession) -> Bool = { $0.record.taskID == session.record.taskID }
        let siblings = threadOrder(in: session.record.scopeID).filter(sameGroup)
        let position = siblings.firstIndex { $0.id == id } ?? 0
        threads.removeAll { $0.id == id }
        guard wasSelected else { return }
        let remaining = threadOrder(in: session.record.scopeID).filter(sameGroup)
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
    /// The record file of a stopped thread was removed outside the app: the thread goes the way a closed one does,
    /// except that nothing is deleted — the file is gone already — and the history gets no line.
    func dropThread(removedOutside id: ThreadID) async {
        guard let session = session(id), !session.isAlive else { return }
        residentRestarts.removeValue(forKey: id)?.cancel()
        residentHolds[id] = nil
        residentQuickExits[id] = nil
        takeExitNotice(id)
        detach(session)
        session.onActivityChanged = nil
        session.onClaudePullRequests = nil
        session.onRecordChanged = nil
        env.knownThreads.remove(id)
        autoRelaunchBlocks[id] = nil
        problems.dismissAll(thread: id)
        await forgetActivity(id)
        forgetAssist(id)
    }

    private func forget(id: ThreadID, scopeID: ScopeID, profile: DriverProfile) async {
        env.knownThreads.remove(id)
        autoRelaunchBlocks[id] = nil
        AdapterInstaller.remove(profile: profile, threadID: id, home: env.home)
        problems.dismissAll(thread: id)
        await env.threadRecords.delete(id)
        await forgetActivity(id)
        forgetAssist(id)
    }

    private func confirmClose(_ session: ThreadSession, risks: [CloseGuard.Risk]) async -> Bool {
        await confirmDestructive(title: "Close “\(session.title)”?", verb: "Close", risks: risks)
    }

    /// The one question before a close or an archive that would lose something. Cancel is the default button: a
    /// Return typed for the terminal a moment earlier must not confirm, and the destructive answer takes a click.
    func confirmDestructive(title: String, verb: String, risks: [CloseGuard.Risk]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = CloseGuard.describe(risks).joined(separator: "\n")
        alert.addButton(withTitle: "Cancel")
        let destructive = alert.addButton(withTitle: verb)
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
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
        let requested = stopRequests.remove(session.id) != nil
        guard !isTerminating, !closingThreads.contains(session.id),
              threads.contains(where: { $0.id == session.id }) else { return }
        // Never a toast or an auto-close: Scope starts it again, or says in its banner why not.
        if session.record.resident != nil {
            residentExited(session, status: status, requested: requested)
            return
        }
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
            await keepTimeline(of: notice.record, activity: nil)
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
        forgetUndo(id: "thread:\(id.rawValue)")
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

    /// The sidebar's own order — the residents (⌘1 is the orchestrator, ⌘2 the terminal), each task's threads in task
    /// order, then the loose threads. The
    /// sidebar is the only thread switcher, so ⌘1…⌘9, ⇧⌘[ / ⇧⌘] and the pick after a close all walk it.
    func threadOrder(in scope: ScopeID) -> [ThreadSession] {
        residents(in: scope) + tasks(in: scope).flatMap { threads(in: $0.id) } + scopeLevelThreads(in: scope)
    }

    // MARK: Scope navigation

    /// ⌃1…⌃9: the scope at `index` in the declared order.
    func selectScope(index: Int) {
        guard scopes.indices.contains(index) else { return }
        selectScope(scopes[index].id)
    }

    /// The scope `delta` places from the current one around the ring (`ScopeCycle`): what a swipe pages to, and
    /// what the header tiles are arranged by. The ring has no end — past the last scope comes the first — so this
    /// is `nil` only when there is no other scope to reach, where a swipe rubber-bands instead.
    func adjacentScope(_ delta: Int) -> ScopeID? {
        guard let current = currentScope else { return nil }
        return ScopeCycle.neighbour(of: current.id, in: scopes.map(\.id), delta: delta)
    }

    /// ⌥⌘→ / ⌥⌘←: the next or previous scope around the ring.
    func selectAdjacentScope(_ delta: Int) {
        guard let target = adjacentScope(delta) else { return }
        noteScopeSwipe()
        scopeStepForward = delta > 0
        defer { scopeStepForward = nil }
        selectScope(target)
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

    // MARK: Adapter events

    func handle(_ event: AdapterEvent) {
        // The status line's figures: the limits are about the account (the meter takes them), the context window
        // about the thread (its activity keeps it); no session state moves either way.
        if event.kind == .limitsReported {
            receiveLimits(event)
            session(event.threadID)?.receiveStatus(event)
            return
        }
        guard let session = session(event.threadID), session.isAlive else { return }
        // A late event changed nothing: no "needs your permission" for a thread whose turn is over.
        if session.apply(event) {
            assistThenNotify(event, session: session)
            if event.kind == .turnEnded || event.kind == .turnFailed { scheduleCheckpoint(after: session) }
            refreshReading(for: session, turnEnded: event.kind == .turnEnded || event.kind == .turnFailed)
        }
        readClaudeTranscriptSoon(session)
        if event.kind == .driverReported { confirmPermissionSoon(session) }
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
        case .retryTaskCleanup(let raw):
            if let id = TaskID(rawValue: raw) { Task { await retryCleanup(id) } }
        case .reopenTask(let raw):
            if let id = TaskID(rawValue: raw) { Task { await reopenTask(id) } }
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
        // The user's checkouts come back first, before anything is hung up: no confirmation, no base left on a task.
        await putBackAll(reason: "Scope quit")
        for session in threads where session.isAlive {
            // A turn in progress is cut short here: the relaunch asks the agent to go on (`InterruptedTurn`).
            session.markInterruptedTurn()
            session.stoppingForQuit = true
            await env.threadRecords.save(session.record)
        }
        for session in threads where session.isAlive {
            session.stop(escalateAfter: 1.5)
        }
        stopAllTaskShells()
        stampCurrentVisit()
        env.uiState.flush()
        await env.config.flush()
        Usage.closeAll()
        await env.usage.flush()
        await journalStop(hungUp: threads.filter(\.stoppingForQuit).count)
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

/// The scopes beside the current one in the header, in ring order, with what is happening in each — worked out
/// once, then split as many times as the header tries a width.
struct ScopeTiles {
    let ring: [(scope: ScopeState, activity: ScopeActivity)]
    let order: ScopeTileOrder

    var count: Int { ring.count }

    /// The `visible` scopes that keep a tile and the ones behind the `+N` counter, both in ring order.
    func split(visible: Int) -> (shown: [ScopeState], hidden: [ScopeState]) {
        let ids = order.split(ring.map { (id: $0.scope.id, activity: $0.activity) }, visible: visible)
        let byID = Dictionary(uniqueKeysWithValues: ring.map { ($0.scope.id, $0.scope) })
        return (ids.shown.compactMap { byID[$0] }, ids.hidden.compactMap { byID[$0] })
    }
}

// MARK: Lifecycle in the event journal

extension AppModel {
    /// `app.start`, with how the previous session ended. Also a `notice` in the unified log, which keeps it on disk.
    fileprivate func journalStart(previous: JournalSession?, threads: Int, skippedRelaunch: Bool) {
        var end = previous?.end ?? .first
        if end == .unclean, let previous,
           SessionEnd.crashReported(process: ProcessInfo.processInfo.processName, since: previous.startedAt) {
            end = .crashed
        }
        Journal.record(JournalEvent(kind: .appStart, outcome: end.rawValue, cause: skippedRelaunch ? "shift" : nil,
                                    version: env.appVersion, previous: previous?.version, seconds: previous?.length,
                                    count: threads))
        Log.app.notice("started \(self.env.appVersion, privacy: .public) (\(BuildFlavor.displayName, privacy: .public)): \(self.scopes.count) scopes, \(threads) threads; previous session \(end.rawValue, privacy: .public)\(previous.map { " (\($0.version), \(Int($0.length)) s)" } ?? "", privacy: .public)")
    }

    /// `app.stop`, then the session marker is closed: the next launch reads it as a clean quit, or an update.
    fileprivate func journalStop(hungUp: Int) async {
        let reason = AppServices.stopReason
        let length = await env.journal.sessionLength()
        Journal.record(JournalEvent(kind: .appStop, cause: reason.rawValue, version: env.appVersion, seconds: length, count: hungUp))
        Log.app.notice("stopping (\(reason.rawValue, privacy: .public)) after \(Int(length)) s, \(hungUp) threads hung up")
        await env.journal.endSession(reason: reason)
    }
}
