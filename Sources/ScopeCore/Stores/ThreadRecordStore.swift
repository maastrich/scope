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

    private var refused: Set<ThreadID> = []

    public init(home: URL) {
        directory = ScopeHome.threadsURL(home: home)
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
                record.lastState = record.lastState?.normalizedAfterRestart
                records.append(record)
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
            try JSONStore.save(record, to: url(for: record.id), fractionalSeconds: true)
        } catch {
            Log.threads.error("thread record \(record.id) write failed: \(String(describing: error))")
        }
    }

    /// Removes `<id>.json`. A missing file is not an error.
    public func delete(_ id: ThreadID) async {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.threads.error("thread record \(id) delete failed: \(String(describing: error))")
        }
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }
}
