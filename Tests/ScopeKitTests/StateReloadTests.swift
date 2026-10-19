import Foundation
import Synchronization
import Testing
import ScopeGit
@testable import ScopeCore
@testable import ScopeTasks

/// The state documents (`config.json`, `tasks/*.json`, `threads/*.json`) reload when something outside the app
/// changes them, and never when the app itself writes them (`RecordLedger`, `StateFolderWatcher`,
/// `StateFileWatcher`, the stores' `reloadExternalChanges`).
@Suite struct StateReloadTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "scope-reload-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try ScopeHome.ensureLayout(at: home)
        return home
    }

    private func task(_ name: String, topic: String? = nil) -> TaskRecord {
        TaskRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/work/acme", scopeSlug: "acme", name: name,
                   slug: name.lowercased(), branch: "feat/\(name.lowercased())", root: "/home/sandboxes/acme/\(name.lowercased())",
                   createdAt: Date(timeIntervalSince1970: 1_760_000_000.25), topic: topic)
    }

    private func thread(_ title: String) -> ThreadRecord {
        ThreadRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/work/acme", driverID: "claude-code",
                     title: title, cwd: "/work/acme", cwdKind: .scopeRoot, createdAt: Date(timeIntervalSince1970: 1_760_000_000.25))
    }

    /// Writes `record` the way an editor would: a plain rewrite, not through the store.
    private func editOutside<T: Encodable>(_ record: T, at url: URL) throws {
        try JSONStore.makeEncoder(fractionalSeconds: true).encode(record).write(to: url)
    }

    // MARK: Ledger

    @Test func ledgerTellsTheAppsBytesFromAnybodyElses() {
        var ledger = RecordLedger<String>()
        ledger.noteWritten("a", Data("one".utf8))
        ledger.noteWritten("b", Data("two".utf8))

        let changes = ledger.diff(files: [("a", Data("one".utf8)), ("b", Data("TWO".utf8)), ("c", Data("new".utf8)), ("d", nil)])
        #expect(changes.changed.map(\.id) == ["b", "c"])
        #expect(changes.removed.isEmpty)
        #expect(changes.unreadable == ["d"])

        let gone = ledger.diff(files: [("b", Data("two".utf8))])
        #expect(gone.changed.isEmpty && gone.removed == ["a"])
    }

    // MARK: Task records

    @Test func anOutsideEditIsReloadedAndTheStoresOwnWriteIsNot() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let original = task("Auth", topic: "auth")
        try await store.save(original)

        // The app's own write: the event it caused finds nothing new.
        #expect(await store.reloadExternalChanges().isEmpty)

        var renamed = original
        renamed.topic = "Auth rework"
        try editOutside(renamed, at: store.url(for: original.id))
        let reload = await store.reloadExternalChanges()
        #expect(reload.changed == [renamed] && reload.removed.isEmpty && reload.skipped.isEmpty)

        // Reloaded bytes are the app's own now: nothing comes back twice, and the app saving the very record it
        // just took in is not a change either (no ping-pong).
        #expect(await store.reloadExternalChanges().isEmpty)
        try await store.save(renamed)
        #expect(await store.reloadExternalChanges().isEmpty)
    }

    @Test func aFileThatDoesNotDecodeIsSkippedAndKeptUntilItIsValidAgain() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let original = task("Auth")
        try await store.save(original)
        let url = store.url(for: original.id)

        try Data("{ \"version\": 1, \"name\": \"half".utf8).write(to: url)
        let broken = await store.reloadExternalChanges()
        #expect(broken.isEmpty && broken.skipped.count == 1)
        // Not quarantined, not rewritten: the file is somebody's work in progress.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data("{ \"version\": 1, \"name\": \"half".utf8))

        var fixed = original
        fixed.name = "Auth (fixed)"
        try editOutside(fixed, at: url)
        #expect(await store.reloadExternalChanges().changed == [fixed])
    }

    @Test func aNewerSchemaOnDiskIsLeftAlone() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let original = task("Auth")
        try await store.save(original)
        var newer = original
        newer.version = TaskRecord.currentVersion + 1
        try editOutside(newer, at: store.url(for: original.id))
        let reload = await store.reloadExternalChanges()
        #expect(reload.isEmpty && reload.skipped.count == 1)
    }

    @Test func aFileRemovedOutsideIsReportedOnceAndTheStoresOwnDeleteIsNot() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let gone = task("Gone"), kept = task("Kept")
        try await store.save(gone)
        try await store.save(kept)

        try FileManager.default.removeItem(at: store.url(for: gone.id))
        let reload = await store.reloadExternalChanges()
        #expect(reload.removed == [gone.id] && reload.changed.isEmpty)
        #expect(await store.reloadExternalChanges().isEmpty)

        try await store.delete(kept.id)
        #expect(await store.reloadExternalChanges().isEmpty)
    }

    @Test func aFileCreatedOutsideIsANewRecord() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        _ = await store.loadAll()
        let fresh = task("Fresh")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try editOutside(fresh, at: store.url(for: fresh.id))
        // A stray file whose name is not an id is not a document.
        try Data("{}".utf8).write(to: store.directory.appending(path: "notes.json"))
        #expect(await store.reloadExternalChanges().changed == [fresh])
    }

    @Test func theManagerTakesTheDiskAsItIs() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let manager = TaskManager(home: home, registry: GitClientRegistry(gitPath: "/usr/bin/git"), store: store)
        let a = task("A", topic: "x"), b = task("B", topic: "x")
        try await store.save(a)
        try await store.save(b)
        _ = await manager.loadAll()

        var renamed = a
        renamed.topic = "y"
        try editOutside(renamed, at: store.url(for: a.id))
        try FileManager.default.removeItem(at: store.url(for: b.id))
        let reload = await manager.reloadExternalChanges()
        #expect(reload.changed == [renamed] && reload.removed == [b.id])
        #expect(await manager.task(a.id)?.topic == "y")
        #expect(await manager.task(b.id) == nil)
        // The reload wrote nothing: the manager's write count of the file is what the editor left.
        #expect(try Data(contentsOf: store.url(for: a.id)) == JSONStore.makeEncoder(fractionalSeconds: true).encode(renamed))
    }

    // MARK: Thread records

    @Test func threadRecordsReloadTheSameWay() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let original = thread("look at CI")
        await store.save(original)
        #expect(await store.reloadExternalChanges().isEmpty)

        var retitled = original
        retitled.title = "CI is red"
        try editOutside(retitled, at: store.url(for: original.id))
        #expect(await store.reloadExternalChanges().changed == [retitled])
        #expect(await store.reloadExternalChanges().isEmpty)

        try FileManager.default.removeItem(at: store.url(for: original.id))
        #expect(await store.reloadExternalChanges().removed == [original.id])
    }

    // MARK: Config

    @Test func configReloadsAnOutsideEditButNotItsOwnWriteNorWhileASaveIsPending() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home, saveDelay: .milliseconds(40))
        var config = ScopeConfig.empty
        config.preferences.branchPrefix = "feat/"
        await store.save(config)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await store.writeCount == 1)
        #expect(await store.reloadIfChanged() == nil)

        var edited = config
        edited.preferences.branchPrefix = "fix/"
        try editOutside(edited, at: store.url)
        #expect(await store.reloadIfChanged() == edited)
        #expect(await store.reloadIfChanged() == nil)

        // A save the app has not written yet wins over the disk; once written, the disk is the app's again.
        var later = edited
        later.preferences.branchPrefix = "chore/"
        await store.save(later)
        var outside = edited
        outside.preferences.branchPrefix = "docs/"
        try editOutside(outside, at: store.url)
        #expect(await store.reloadIfChanged() == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await store.reloadIfChanged() == nil)
        #expect(try JSONStore.load(ScopeConfig.self, from: store.url) == later)

        try Data("not json".utf8).write(to: store.url)
        #expect(await store.reloadIfChanged() == nil)
        #expect(try Data(contentsOf: store.url) == Data("not json".utf8))
    }

    // MARK: Watchers

    @Test func aBurstOfWritesWakesTheFolderWatcherOnce() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let wakes = Mutex(0)
        let watcher = StateFolderWatcher(folder: store.directory, names: { $0.hasSuffix(".json") }, delay: .milliseconds(200)) {
            wakes.withLock { $0 += 1 }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        for name in ["A", "B", "C", "D", "E"] {
            try await store.save(task(name))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(2))
        #expect(wakes.withLock { $0 } == 1)

        // A file the names filter rejects does not wake anyone.
        try Data("x".utf8).write(to: store.directory.appending(path: "scratch.txt"))
        try await Task.sleep(for: .seconds(1))
        #expect(wakes.withLock { $0 } == 1)
    }

    @Test func theAppsOwnWritesNeverTurnIntoAReloadThroughTheWatcher() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let reloads = Mutex<[Int]>([])
        let watcher = StateFolderWatcher(folder: store.directory, names: { $0.hasSuffix(".json") }, delay: .milliseconds(150)) {
            let reload = await store.reloadExternalChanges()
            reloads.withLock { $0.append(reload.changed.count + reload.removed.count) }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let record = task("Own")
        try await store.save(record)
        try await Task.sleep(for: .seconds(1))
        // Woken by its own write, with nothing to reload.
        #expect(reloads.withLock { $0 } == [0])

        var edited = record
        edited.name = "Own, edited"
        try editOutside(edited, at: store.url(for: record.id))
        try await Task.sleep(for: .seconds(1))
        #expect(reloads.withLock { $0 } == [0, 1])

        // The app writes the record it just took in (what a reload that re-saved would do): no second reload.
        try await store.save(edited)
        try await Task.sleep(for: .seconds(1))
        #expect(reloads.withLock { $0 } == [0, 1, 0])
    }

    @Test func theFileWatcherSeesAnAtomicWriteAndARewriteInPlace() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = ScopeHome.configURL(home: home)
        let wakes = Mutex(0)
        let watcher = StateFileWatcher(file: url, delay: .milliseconds(150)) { wakes.withLock { $0 += 1 } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        // The file does not exist yet: its creation is an entry added to the directory.
        try JSONStore.save(ScopeConfig.empty, to: url)
        try await Task.sleep(for: .seconds(1))
        #expect(wakes.withLock { $0 } == 1)

        // Rewritten in place (no rename): the file's own source.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        try await Task.sleep(for: .seconds(1))
        #expect(wakes.withLock { $0 } == 2)

        // Renamed over (an atomic write): the directory source, and the file source re-armed on the new inode.
        var edited = ScopeConfig.empty
        edited.preferences.branchPrefix = "feat/"
        try JSONStore.save(edited, to: url)
        try await Task.sleep(for: .seconds(1))
        #expect(wakes.withLock { $0 } == 3)
        let again = try FileHandle(forWritingTo: url)
        try again.seekToEnd()
        try again.write(contentsOf: Data("\n".utf8))
        try again.close()
        try await Task.sleep(for: .seconds(1))
        #expect(wakes.withLock { $0 } == 4)
    }
}
