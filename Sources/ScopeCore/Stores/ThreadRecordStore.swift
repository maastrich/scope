import Foundation

/// A per-file problem met while loading a store directory. Non-fatal: the other files still load.
public struct StoreProblem: Sendable, Equatable {
    /// The file concerned (its original location).
    public var file: URL
    /// One line, e.g. `"corrupt JSON (moved to …)"` or `"schema version 2 is newer than this build"`.
    public var message: String
    /// Where a corrupt file was moved, when it was.
    public var backup: URL?

    public init(file: URL, message: String, backup: URL? = nil) {
        self.file = file
        self.message = message
        self.backup = backup
    }
}

/// Owner of `<home>/threads/<id>.json`.
///
/// Records are tiny, so every save is an immediate atomic write. Files with a newer schema
/// version are reported, skipped and never overwritten; corrupt files are renamed
/// `<id>.corrupt-<timestamp>.json` and reported.
public actor ThreadRecordStore {
    /// `<home>/threads/`
    public nonisolated let directory: URL
    /// Where `delete` leaves the closed thread's line (`ActivityHistory`).
    private let home: URL

    private var refused: Set<ThreadID> = []
    /// The bytes of every record last read or written (`RecordLedger`): what `reloadExternalChanges` compares against.
    private var ledger = RecordLedger<ThreadID>()

    public init(home: URL) {
        directory = ScopeHome.threadsURL(home: home)
        self.home = home
    }

    /// `<home>/threads/<id>.json`
    public nonisolated func url(for id: ThreadID) -> URL {
        directory.appending(path: "\(id.rawValue).json", directoryHint: .notDirectory)
    }

    /// Loads every `<id>.json` (files whose stem is not a thread id are ignored), sorted by `createdAt`.
    ///
    /// Every alive `lastState` is normalized to `.idle`: after a restart no process is running.
    public func loadAll() async -> (records: [ThreadRecord], problems: [StoreProblem]) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            // A missing directory simply means no records yet.
            return ([], [])
        }

        var records: [ThreadRecord] = []
        var problems: [StoreProblem] = []

        for file in files {
            guard file.pathExtension == "json",
                  let id = ThreadID(rawValue: file.deletingPathExtension().lastPathComponent)
            else { continue }

            do {
                let data = try Data(contentsOf: file)
                let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version
                if version > ThreadRecord.currentVersion {
                    refused.insert(id)
                    problems.append(StoreProblem(
                        file: file,
                        message: "schema version \(version) is newer than this build (\(ThreadRecord.currentVersion)); not loaded"
                    ))
                    continue
                }
                var record = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: data)
                guard record.id == id else {
                    problems.append(StoreProblem(file: file, message: "record id \(record.id) does not match the file name; not loaded"))
                    continue
                }
                // Before the state is normalised: a record still mid-turn here was not written by a quit.
                record = InterruptedTurn.noting(record, now: .now)
                record.lastState = record.lastState?.normalizedAfterRestart
                records.append(record)
                ledger.noteLoaded(id, data)
            } catch {
                let message = String(describing: error)
                let backup = try? JSONStore.quarantine(file)
                Log.threads.error("thread record \(file.lastPathComponent) is corrupt: \(message)")
                problems.append(StoreProblem(
                    file: file,
                    message: backup.map { "corrupt JSON (moved to \($0.lastPathComponent))" } ?? "corrupt JSON",
                    backup: backup
                ))
            }
        }

        records.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
        return (records, problems)
    }

    /// Immediate atomic write of `<id>.json`. Dropped (and logged) for ids refused by `loadAll`.
    public func save(_ record: ThreadRecord) async {
        guard !refused.contains(record.id) else {
            Log.threads.error("thread record \(record.id) not saved: the file on disk has a newer schema version")
            return
        }
        do {
            let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(record)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: record.id), options: [.atomic])
            ledger.noteWritten(record.id, data)
        } catch {
            Log.threads.error("thread record \(record.id) write failed: \(String(describing: error))")
        }
    }

    /// Reads the records whose file changed on disk since the store last read or wrote it, and names the ones
    /// whose file is gone. For the watcher of `threads/` (`StateFolderWatcher`); see `TaskRecordStore` for the rules.
    public func reloadExternalChanges() -> ExternalReload<ThreadRecord, ThreadID> {
        var reload = ExternalReload<ThreadRecord, ThreadID>()
        let changes = ledger.diff(files: Self.listRecords(in: directory, id: ThreadID.init(rawValue:)))
        for (id, data) in changes.changed {
            do {
                let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version
                guard version <= ThreadRecord.currentVersion else {
                    reload.skipped.append("\(id.rawValue).json: schema version \(version) is newer than this build")
                    continue
                }
                let record = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: data)
                guard record.id == id else {
                    reload.skipped.append("\(id.rawValue).json: record id \(record.id) does not match the file name")
                    continue
                }
                ledger.noteLoaded(id, data)
                reload.changed.append(record)
            } catch {
                reload.skipped.append("\(id.rawValue).json: \(String(describing: error))")
            }
        }
        for id in changes.removed {
            ledger.noteRemoved(id)
            reload.removed.append(id)
        }
        for line in reload.skipped { Log.threads.error("thread record changed on disk but was not taken: \(line, privacy: .public)") }
        return reload
    }

    /// Every `<id>.json` of `folder` with its bytes (`nil` when unreadable); other names are not documents.
    public static func listRecords<ID>(in folder: URL, id: (String) -> ID?) -> [(id: ID, data: Data?)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let id = id(file.deletingPathExtension().lastPathComponent) else { return nil }
            return (id, try? Data(contentsOf: file))
        }
    }

    /// Removes `<id>.json`, after writing what it held to the history: once it is gone, nothing else says the
    /// thread existed. A missing file is not an error.
    public func delete(_ id: ThreadID) async {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let data = try? Data(contentsOf: file),
           let record = try? JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: data) {
            ActivityHistory.append(.threadClosed(record.snapshot), home: home)
        }
        do {
            try FileManager.default.removeItem(at: file)
            ledger.noteRemoved(id)
        } catch {
            Log.threads.error("thread record \(id) delete failed: \(String(describing: error))")
        }
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }
}
