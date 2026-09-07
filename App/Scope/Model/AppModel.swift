import AppKit
import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers
import ScopeGit
import SwiftUI

/// The root store: scopes, threads, selection, and every user action. One per app.
@MainActor
@Observable
final class AppModel {
    let env: AppEnvironment
    let problems = ProblemCenter()
    private(set) var config: ScopeConfig = .empty
    /// Sidebar order == `config.scopes` order.
    private(set) var scopes: [ScopeState] = []
    /// Creation order; tabs filter by scope.
    private(set) var threads: [ThreadSession] = []
    private(set) var drivers = LoadedDrivers(profiles: [])
    private(set) var shellStatus: ShellStatus = .probing
    private(set) var isBootstrapped = false
    /// Threads that exited live: tab gone, record kept until the toast expires or is dismissed.
    private(set) var exitNotices: [ThreadExitNotice] = []

    /// Drives the sidebar highlight. Selecting a thread selects its tab; selecting a scope or repo shows
    /// the scope's last thread (or its empty state).
    var selection: SidebarItem? {
        didSet {
            guard !isRestoringUIState else { return }
            syncThreadFromSelection()
            persistUIState()
        }
    }

    /// Drives the scene. Kept in sync with `selection`.
    var selectedThreadID: ThreadID? {
        didSet {
            if let id = selectedThreadID, let session = session(id) {
                lastThreadByScope[session.record.scopeID] = id
            }
            if !isRestoringUIState { persistUIState() }
        }
    }

    var inspectorShown = false {
        didSet { if !isRestoringUIState { persistUIState() } }
    }

    var inspectorTab: InspectorTab = .graph {
        didSet { if !isRestoringUIState { persistUIState() } }
    }

    @ObservationIgnored private var lastThreadByScope: [ScopeID: ThreadID] = [:]
    @ObservationIgnored private var isRestoringUIState = false
    @ObservationIgnored private var reportedShellWarning = false
    @ObservationIgnored private var launcher: ThreadLauncher
    /// Threads being closed by the user (`close`) or by termination: their exit is not a live exit.
    @ObservationIgnored private var closingThreads: Set<ThreadID> = []
    @ObservationIgnored private var isTerminating = false

    init(env: AppEnvironment) {
        self.env = env
        self.launcher = ThreadLauncher(env: env)
        problems.onAction = { [weak self] action in self?.perform(action) }
        env.hookSink.handler = { [weak self] event in self?.handle(event) }
        for problem in env.startupProblems { problems.report(problem) }
    }

    // MARK: Lookup

    var currentScope: ScopeState? {
        switch selection {
        case .scope(let id), .repo(let id, _):
            return scope(id)
        case .thread(let id):
            return session(id).flatMap { scope($0.record.scopeID) }
        case nil:
            return selectedThreadID.flatMap(session).flatMap { scope($0.record.scopeID) }
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

    /// The profile for an id, falling back to `shell`, then the first profile.
    func profile(id: String?) -> DriverProfile? {
        if let id, let profile = drivers.profile(id: id) { return profile }
        return drivers.profile(id: "shell") ?? drivers.profiles.first
    }

    // MARK: Bootstrap

    /// §(d).5: stores in parallel, scopes built and scanned, records rebound, UI state restored.
    func bootstrap() async {
        guard !isBootstrapped else { return }

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
            scope.isExpanded = state.expandedScopes.isEmpty || state.expandedScopes.contains(scope.id)
        }
        inspectorShown = state.inspectorVisible
        inspectorTab = state.inspectorTab
        if let id = state.selectedThread, session(id) != nil {
            selectedThreadID = id
        }
        switch state.selectedItem {
        case .scope(let id) where scope(id) != nil:
            selection = state.selectedItem
        case .repo(let id, _) where scope(id) != nil:
            selection = state.selectedItem
        case .thread(let id) where session(id) != nil:
            selection = state.selectedItem
            selectedThreadID = id
        default:
            selection = nil
        }
        if selection == nil, let scope = scopes.first {
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
        state.expandedScopes = Set(scopes.filter(\.isExpanded).map(\.id))
        state.inspectorVisible = inspectorShown
        state.inspectorTab = inspectorTab
        env.uiState.save(state)
    }

    /// Called by rows when their scope's expansion changes.
    func expansionChanged() {
        persistUIState()
    }

    private func syncThreadFromSelection() {
        switch selection {
        case .thread(let id):
            selectedThreadID = id
        case .scope(let id), .repo(let id, _):
            if let last = lastThreadByScope[id], session(last) != nil {
                selectedThreadID = last
            } else {
                selectedThreadID = threads(in: id).first?.id
            }
        case nil:
            selectedThreadID = nil
        }
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
        scopes.remove(at: index)
        config.scopes.removeAll { $0.id == id }
        saveConfig()
        for repo in scope.repos {
            let url = repo.url
            Task { await env.git.forget(url) }
        }
        if currentScope?.id == id || currentScope == nil {
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
            guard let self else { return }
            Task { await self.env.threadRecords.save(record) }
        }
        session.onExit = { [weak self] session, status in
            self?.threadExited(session, status: status)
        }
        threads.append(session)
        env.knownThreads.insert(session.id)
    }

    @discardableResult
    func newThread(in scopeID: ScopeID, driverID: String? = nil, cwdKind: ThreadCwdKind = .scopeRoot) async -> ThreadSession? {
        guard let scope = scope(scopeID) else { return nil }
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
        let record = ThreadRecord(
            scopeID: scopeID,
            scopeRoot: scope.declaration.path,
            driverID: profile.id,
            title: "\(profile.name) · \(scope.name)",
            cwd: cwd,
            cwdKind: cwdKind
        )
        let session = ThreadSession(record: record, profile: profile)
        register(session)
        await env.threadRecords.save(record)
        selection = .thread(session.id)
        selectedThreadID = session.id
        await launch(session, mode: .launch)
        return session
    }

    private func launch(_ session: ThreadSession, mode: LaunchMode) async {
        guard !session.isAlive else { return }
        guard let scope = scope(session.record.scopeID) else { return }
        session.markLaunching()
        do {
            let plan = try await launcher.plan(record: session.record, profile: session.profile,
                                               scope: scope.declaration, mode: mode)
            session.launch(plan)
        } catch {
            session.fail(error)
            problems.report(error, thread: session.id, scope: scope.id)
        }
    }

    func relaunch(_ id: ThreadID) async {
        guard let session = session(id), !session.isAlive else { return }
        await launch(session, mode: .launch)
    }

    func resume(_ id: ThreadID) async {
        guard let session = session(id), !session.isAlive else { return }
        await launch(session, mode: session.canResume ? .resume : .launch)
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
        detach(session)
        await forget(id: id, scopeID: session.record.scopeID, profile: session.profile)
        return true
    }

    /// Removes the tab (and the terminal view with it) and moves the selection to a neighbour or the
    /// scope's empty view. The record stays on disk.
    private func detach(_ session: ThreadSession) {
        let id = session.id
        let wasSelected = selectedThreadID == id
        let siblings = threads(in: session.record.scopeID)
        let position = siblings.firstIndex { $0.id == id } ?? 0
        threads.removeAll { $0.id == id }
        if lastThreadByScope[session.record.scopeID] == id {
            lastThreadByScope[session.record.scopeID] = nil
        }
        guard wasSelected else { return }
        let remaining = threads(in: session.record.scopeID)
        if let neighbour = remaining[safe: min(position, remaining.count - 1)] {
            selection = .thread(neighbour.id)
            selectedThreadID = neighbour.id
        } else {
            selection = .scope(session.record.scopeID)
            selectedThreadID = nil
        }
    }

    /// The permanent part of a close: hook files, problems, the persisted record.
    private func forget(id: ThreadID, scopeID: ScopeID, profile: DriverProfile) async {
        env.knownThreads.remove(id)
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

    /// A live exit closes the tab and shows a toast for 10 s (Relaunch / Details); the record is
    /// deleted when the toast goes. Exits caused by `close` or by quitting keep their own paths.
    private func threadExited(_ session: ThreadSession, status: ExitStatus) {
        if status.isExecFailure {
            problems.error("\(session.profile.name) could not be started (exit 127)",
                           detail: "Check the \"command\" of the \(session.profile.id) driver profile.",
                           scope: session.record.scopeID,
                           actions: [.reveal(ScopeHome.driversURL(home: env.home).path)])
        }
        guard !isTerminating, !closingThreads.contains(session.id),
              threads.contains(where: { $0.id == session.id }) else { return }
        detach(session)
        let notice = ThreadExitNotice(record: session.record, profile: session.profile,
                                      status: status, lastTitle: session.terminalTitle)
        notice.onExpire = { [weak self] notice in
            Task { await self?.dismissExitNotice(notice.id) }
        }
        exitNotices.append(notice)
        notice.start()
    }

    /// Explicit dismiss or the 10 s countdown: the thread is closed for good.
    func dismissExitNotice(_ id: ThreadID) async {
        guard let notice = takeExitNotice(id) else { return }
        await forget(id: id, scopeID: notice.record.scopeID, profile: notice.profile)
    }

    /// Reopens the tab for the same record and starts a fresh process.
    func relaunchExitNotice(_ id: ThreadID) async {
        guard let notice = takeExitNotice(id), scope(notice.record.scopeID) != nil else { return }
        let session = ThreadSession(record: notice.record, profile: notice.profile)
        register(session)
        selection = .thread(id)
        selectedThreadID = id
        await launch(session, mode: .launch)
    }

    /// Hovering a toast holds its countdown.
    func holdExitNotice(_ id: ThreadID, _ held: Bool) {
        guard let notice = exitNotices.first(where: { $0.id == id }) else { return }
        held ? notice.pause() : notice.start()
    }

    private func takeExitNotice(_ id: ThreadID) -> ThreadExitNotice? {
        guard let index = exitNotices.firstIndex(where: { $0.id == id }) else { return nil }
        let notice = exitNotices.remove(at: index)
        notice.cancel()
        return notice
    }

    // MARK: Tab navigation

    private var currentTabs: [ThreadSession] {
        currentScope.map { threads(in: $0.id) } ?? []
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

    /// ⌘E: the thread's cwd, else the selected repo, else the scope root.
    func openInEditor(thread id: ThreadID?) {
        guard let editor = config.preferences.editor else { return }
        var path: String?
        if let id, let session = session(id) {
            path = session.reportedDirectory ?? session.record.cwd
        } else if case .repo(let scopeID, let relativePath) = selection, let scope = scope(scopeID) {
            path = scope.repo(relativePath: relativePath)?.url.path ?? scope.url.appending(path: relativePath).path
        } else if let scope = currentScope {
            path = scope.url.path
        }
        guard let path else { return }
        let searchPATH: String
        switch shellStatus {
        case .ready(let environment), .fallback(let environment):
            searchPATH = environment.path
        case .probing:
            searchPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        }
        do {
            try editor.launch(path: path, searchPATH: searchPATH)
        } catch {
            problems.error("Could not open the editor", detail: String(describing: error),
                           actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
        }
    }

    // MARK: Adapter events

    func handle(_ event: AdapterEvent) {
        session(event.threadID)?.apply(event)
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
    func terminateNow() async {
        isTerminating = true
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
