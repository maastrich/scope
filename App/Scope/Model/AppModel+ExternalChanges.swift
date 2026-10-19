import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// The three watchers of the state documents under the home: `config.json`, `tasks/*.json`, `threads/*.json`.
@MainActor
final class StateWatchers {
    let config: StateFileWatcher
    let tasks: StateFolderWatcher
    let threads: StateFolderWatcher

    init(config: StateFileWatcher, tasks: StateFolderWatcher, threads: StateFolderWatcher) {
        self.config = config
        self.tasks = tasks
        self.threads = threads
    }

    func start() {
        config.start()
        tasks.start()
        threads.start()
    }

    func stop() {
        config.stop()
        tasks.stop()
        threads.stop()
    }
}

/// The state on disk is the state: somebody who edits `tasks/<id>.json` in an editor, removes a thread's record
/// or fixes `config.json` by hand sees the sidebar, the inspector and the CLI follow without a restart (spec §3).
///
/// How a loop is avoided: nothing here asks who wrote a file. Every store keeps the SHA-256 of the bytes it last
/// wrote or read (`RecordLedger`); an event whose bytes match is the app's own write and is dropped before
/// anything is decoded. A reload takes the disk as it is and writes nothing, so it cannot cause an event of its
/// own; and if the app later saves the record it just took in, that write's bytes are noted first, and the event
/// it causes is dropped the same way. Rafales are one wake (`Debouncer`), and a file that does not decode is left
/// alone until it does.
///
/// Who wins: the disk, in every case but two. A `ConfigStore` save still pending (150 ms) lands over an outside
/// edit made in that window, and a task being dismantled keeps writing its own record until it is done. Every
/// other change the app makes is on disk before it is in memory, so there is nothing newer in memory to lose.
extension AppModel {
    /// Starts the watchers once the state is loaded (end of bootstrap).
    func startWatchingState() {
        guard stateWatchers == nil else { return }
        let env = env
        let isDocument: @Sendable (String) -> Bool = { name in
            // `<id>.json` only: not `.activity.json`, `.timeline.json`, `.checkpoints.json`, nor a quarantined copy.
            name.hasSuffix(".json") && !name.dropLast(5).contains(".")
        }
        let watchers = StateWatchers(
            config: StateFileWatcher(file: env.config.url) { [weak self] in
                guard let config = await env.config.reloadIfChanged() else { return }
                await self?.applyExternalConfig(config)
            },
            tasks: StateFolderWatcher(folder: env.taskRecords.directory, names: isDocument) { [weak self] in
                let reload = await env.tasks.reloadExternalChanges()
                guard !reload.isEmpty else { return }
                await self?.applyExternalTaskChanges(reload)
            },
            threads: StateFolderWatcher(folder: env.threadRecords.directory, names: isDocument) { [weak self] in
                let reload = await env.threadRecords.reloadExternalChanges()
                guard !reload.isEmpty else { return }
                await self?.applyExternalThreadChanges(reload)
            }
        )
        stateWatchers = watchers
        watchers.start()
    }

    // MARK: Tasks

    /// Records changed or removed behind the app: the matching `TaskState`s follow, new ones appear, gone ones
    /// leave the sidebar. Sandboxes on disk are not touched: a record removed by hand is a task forgotten, not
    /// closed — its folders stay for `scope gc` and its threads become loose ones.
    func applyExternalTaskChanges(_ reload: ExternalReload<TaskRecord, TaskID>) {
        var touchedScopes: Set<ScopeID> = []
        for record in reload.changed {
            touchedScopes.insert(record.scopeID)
            if let task = task(record.id) {
                let wasLive = !task.isArchived
                task.update(record: record)
                if task.isArchived, wasLive {
                    task.stopWatching()
                } else if !task.isArchived, !wasLive {
                    task.startWatching()
                }
            } else {
                let task = TaskState(record: record, git: env.git)
                tasks.append(task)
                if !task.isArchived {
                    task.startWatching()
                    task.refresh()
                }
            }
        }
        for id in reload.removed {
            guard let task = task(id) else { continue }
            touchedScopes.insert(task.scopeID)
            task.stopWatching()
            tasks.removeAll { $0.id == id }
            if selection == .task(id) || currentTask?.id == id {
                selection = .scope(task.scopeID)
            }
            Log.tasks.info("task record \(id.rawValue, privacy: .public) removed on disk; forgotten (its folders are left for gc)")
        }
        for scopeID in touchedScopes { scope(scopeID)?.refreshFacts() }
        if !reload.skipped.isEmpty {
            problems.warn("\(reload.skipped.count) task \(reload.skipped.count == 1 ? "record" : "records") changed on disk but could not be read",
                          detail: reload.skipped.joined(separator: "\n") + "\n\nThe copy in memory is kept until the file decodes again.",
                          actions: [.reveal(env.taskRecords.directory.path)])
        }
    }

    // MARK: Threads

    /// Records changed or removed behind the app. A running thread keeps its process: the record's descriptive
    /// fields follow (`ThreadSession.takeRecord`), its state stays the process's. A file removed under a running
    /// thread is logged and left: the session's next change writes it again. A stopped thread whose file went is
    /// dropped from the sidebar; a file that appeared is a stopped thread, shown, relaunchable.
    func applyExternalThreadChanges(_ reload: ExternalReload<ThreadRecord, ThreadID>) {
        for record in reload.changed {
            if let session = session(record.id) {
                session.takeRecord(fromDisk: record)
            } else {
                let profile = profile(id: record.driverID)
                    ?? DriverProfile(id: "shell", name: "Shell", command: "$SHELL", loginShell: true)
                var record = record
                record.lastState = record.lastState?.normalizedAfterRestart
                register(ThreadSession(record: record, profile: profile))
                env.knownThreads.replaceAll(Set(threads.map(\.id)))
            }
        }
        Task { [weak self] in
            for id in reload.removed {
                guard let self, let session = self.session(id) else { continue }
                if session.isAlive {
                    Log.threads.info("thread record \(id.rawValue, privacy: .public) removed on disk under a running thread; kept, written again at its next change")
                    continue
                }
                await self.dropThread(removedOutside: id)
            }
        }
        if !reload.skipped.isEmpty {
            problems.warn("\(reload.skipped.count) thread \(reload.skipped.count == 1 ? "record" : "records") changed on disk but could not be read",
                          detail: reload.skipped.joined(separator: "\n") + "\n\nThe copy in memory is kept until the file decodes again.",
                          actions: [.reveal(env.threadRecords.directory.path)])
        }
    }

    // MARK: Config

    /// `config.json` changed behind the app: preferences take effect, scopes that vanished are torn down (their
    /// threads closed, like Remove Scope), new ones are declared, changed ones re-watched, the sidebar reordered.
    func applyExternalConfig(_ fresh: ScopeConfig) async {
        let before = config
        guard fresh != before else { return }
        takeConfig(fromDisk: fresh)

        if fresh.preferences != before.preferences {
            if fresh.preferences.shellProbe != before.preferences.shellProbe { reprobeShell() }
            if fresh.preferences.assist != before.preferences.assist { refreshAssistModels() }
        }

        let freshIDs = Set(fresh.scopes.map(\.id))
        for scope in scopes where !freshIDs.contains(scope.id) {
            await tearDownScope(scope.id)
        }
        var added: [ScopeState] = []
        for declaration in fresh.scopes {
            if let scope = scope(declaration.id) {
                let old = scope.declaration
                guard old != declaration else { continue }
                scope.declaration = declaration
                if old.path != declaration.path || old.discoveryDepth != declaration.discoveryDepth {
                    scope.restartWatching()
                    Task { await scope.rescan(full: true) }
                }
            } else {
                added.append(addScope(fromDisk: declaration))
            }
        }
        orderScopes(like: fresh.scopes)
        for scope in added { Task { await scope.rescan() } }
        if !added.isEmpty { await reconcileResidents() }
        Log.app.info("config.json reloaded from disk: \(fresh.scopes.count) scopes")
    }
}
