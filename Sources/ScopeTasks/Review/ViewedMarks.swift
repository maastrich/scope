import Foundation
import ScopeCore
import ScopeGit

/// The files of a task's delta the owner has marked as viewed, with the diff each one had then (`DiffDigest`), kept
/// across launches under `SCOPE_HOME` so a review picks up where it stopped.
///
/// A mark never goes away on its own: when the agent touches a viewed file again, the file is *changed since
/// viewed* — the thing to look at next — rather than silently unviewed, which read as "never looked at". It drops
/// only when the owner unmarks it or when the file leaves the delta.
public struct ViewedMarks: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Mark: Codable, Sendable, Equatable, Hashable {
        public var mode: DeltaMode
        /// `TaskRepo.repoRelativePath` of the repository.
        public var repo: String
        /// The file, relative to the repository.
        public var path: String
        /// `DiffDigest.of` the file's diff when it was marked.
        public var digest: String
        public var at: Date

        public init(mode: DeltaMode, repo: String, path: String, digest: String, at: Date = .now) {
            self.mode = mode
            self.repo = repo
            self.path = path
            self.digest = digest
            self.at = at
        }
    }

    /// What a file's row says about it.
    public enum State: Sendable, Equatable {
        case unviewed
        case viewed(at: Date)
        /// Marked, but the diff is no longer the one that was looked at.
        case changedSinceViewed(at: Date)

        public var isViewed: Bool { if case .viewed = self { return true } else { return false } }
        public var isChanged: Bool { if case .changedSinceViewed = self { return true } else { return false } }
    }

    public var version: Int
    public var marks: [Mark]

    public init(marks: [Mark] = []) {
        version = Self.currentVersion
        self.marks = marks
    }

    public var isEmpty: Bool { marks.isEmpty }

    public func mark(mode: DeltaMode, repo: String, path: String) -> Mark? {
        marks.first { $0.mode == mode && $0.repo == repo && $0.path == path }
    }

    /// The state of a file whose diff digests to `digest` now.
    public func state(mode: DeltaMode, repo: String, path: String, digest: String) -> State {
        guard let mark = mark(mode: mode, repo: repo, path: path) else { return .unviewed }
        return mark.digest == digest ? .viewed(at: mark.at) : .changedSinceViewed(at: mark.at)
    }

    /// Marks the file as viewed with the diff it has now; a mark already there is renewed, so a *changed since
    /// viewed* file marked again is viewed again.
    public mutating func set(mode: DeltaMode, repo: String, path: String, digest: String, at: Date = .now) {
        clear(mode: mode, repo: repo, path: path)
        marks.append(Mark(mode: mode, repo: repo, path: path, digest: digest, at: at))
    }

    public mutating func clear(mode: DeltaMode, repo: String, path: String) {
        marks.removeAll { $0.mode == mode && $0.repo == repo && $0.path == path }
    }

    /// Keeps, in `mode`, only the marks of files still in the delta: a file the agent reverted has nothing left to
    /// review. Other modes are left alone — their files were not looked at.
    public mutating func retain(mode: DeltaMode, present: (Mark) -> Bool) {
        marks.removeAll { $0.mode == mode && !present($0) }
    }

    /// How many of `files` are viewed, for the list header.
    public func counts(mode: DeltaMode, files: [(repo: String, path: String, digest: String)]) -> (viewed: Int, changed: Int) {
        var viewed = 0
        var changed = 0
        for file in files {
            switch state(mode: mode, repo: file.repo, path: file.path, digest: file.digest) {
            case .viewed: viewed += 1
            case .changedSinceViewed: changed += 1
            case .unviewed: break
            }
        }
        return (viewed, changed)
    }
}

/// Owner of `<home>/reviews/<task>.viewed.json`, beside the task's review comments.
public actor ViewedStore {
    public nonisolated let directory: URL

    public init(home: URL) {
        directory = home.appending(path: "reviews", directoryHint: .isDirectory)
    }

    public nonisolated func url(for task: TaskID) -> URL {
        directory.appending(path: "\(task.rawValue).viewed.json", directoryHint: .notDirectory)
    }

    /// The marks of `task`; none when there is no file, it cannot be read, or it was written by another version.
    public func load(_ task: TaskID) -> ViewedMarks {
        guard let marks = try? JSONStore.load(ViewedMarks.self, from: url(for: task), fractionalSeconds: true),
              marks.version == ViewedMarks.currentVersion else { return ViewedMarks() }
        return marks
    }

    /// Writes the marks of `task`; none left removes its file.
    public func save(_ marks: ViewedMarks, for task: TaskID) throws {
        guard !marks.isEmpty else {
            delete(task)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONStore.save(marks, to: url(for: task), fractionalSeconds: true)
    }

    public func delete(_ task: TaskID) {
        try? FileManager.default.removeItem(at: url(for: task))
    }
}
