import Foundation
import ScopeCore

/// Owner of `<home>/tasks/<id>.json`. Same rules as `ThreadRecordStore`: every save is an
/// immediate atomic write; files with a newer schema version are reported, skipped and never
/// overwritten; corrupt files are quarantined (`<id>.corrupt-<timestamp>.json`) and reported.
public actor TaskRecordStore {
    /// `<home>/tasks/`
    public nonisolated let directory: URL
    /// Where `delete` leaves the closed task's line (`ActivityHistory`).
    private let home: URL
    private var refused: Set<TaskID> = []

    public init(home: URL) {
        directory = TaskRecordStore.directoryURL(home: home)
        self.home = home
    }

    /// `<home>/tasks/`
    public static func directoryURL(home: URL) -> URL {
        home.appending(path: "tasks", directoryHint: .isDirectory)
    }

    /// `<home>/tasks/<id>.json`
    public nonisolated func url(for id: TaskID) -> URL {
        directory.appending(path: "\(id.rawValue).json", directoryHint: .notDirectory)
    }

    /// Loads every `<id>.json` (other file names are ignored), sorted by `createdAt` then id.
    public func loadAll() async -> (records: [TaskRecord], problems: [StoreProblem]) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            return ([], [])   // no directory: no tasks yet
        }

        var records: [TaskRecord] = []
        var problems: [StoreProblem] = []
        for file in files {
            guard file.pathExtension == "json", let id = TaskID(rawValue: file.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let data = try Data(contentsOf: file)
                let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version
                if version > TaskRecord.currentVersion {
                    refused.insert(id)
                    problems.append(StoreProblem(
                        file: file,
                        message: "schema version \(version) is newer than this build (\(TaskRecord.currentVersion)); not loaded"
                    ))
                    continue
                }
                let record = try JSONStore.makeDecoder(fractionalSeconds: true).decode(TaskRecord.self, from: data)
                guard record.id == id else {
                    problems.append(StoreProblem(file: file, message: "record id \(record.id) does not match the file name; not loaded"))
                    continue
                }
                records.append(record)
            } catch {
                let backup = try? JSONStore.quarantine(file)
                Log.tasks.error("task record \(file.lastPathComponent) is corrupt: \(String(describing: error))")
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

    /// Immediate atomic write of `<id>.json`. Throws on I/O failure; silently dropped for ids refused by `loadAll`.
    public func save(_ record: TaskRecord) async throws {
        guard !refused.contains(record.id) else {
            Log.tasks.error("task record \(record.id) not saved: the file on disk has a newer schema version")
            return
        }
        try JSONStore.save(record, to: url(for: record.id), fractionalSeconds: true)
    }

    /// Removes `<id>.json` and its timeline, after writing what they held to the history: a closed task leaves
    /// nothing else behind, and a summary of past work still has to name it and say how long it took. Its threads are
    /// hung up before, so the timeline holds all of their turns. A missing file is not an error.
    public func delete(_ id: TaskID) async throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let timeline = TaskTimelineStore.url(for: id, in: directory)
        if let data = try? Data(contentsOf: file),
           let record = try? JSONStore.makeDecoder(fractionalSeconds: true).decode(TaskRecord.self, from: data) {
            let lanes = TaskTimelineStore.load(from: timeline).lanes
            ActivityHistory.append(.taskClosed(record.snapshot(lanes: lanes)), home: home)
        }
        try FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: timeline)
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }
}
