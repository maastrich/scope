import Foundation

/// What a task produced besides code, kept when it is archived or closed: the last answer of each of its threads,
/// and its report file when it wrote one (`REPORT.md`, or the file its record names).
///
/// A study's deliverable is the agent's final answer. Without this it lived in the thread's activity only, which goes
/// with the thread — and archiving a task closes its threads. Kept in `<home>/tasks/deliverables/<id>.json`, beside
/// the record but out of `TaskRecordStore.loadAll`'s way (it only reads `<home>/tasks/*.json`), and it outlives a close.
public struct TaskDeliverable: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// UTF-8 bytes kept of each reply, from its end: an answer's conclusion is at its bottom.
    public static let replyLimit = 64 * 1024
    /// UTF-8 bytes kept of each file, from its start.
    public static let fileLimit = 1024 * 1024
    /// Looked for in the task root and every sandbox, besides the file the task names.
    public static let defaultFileName = "REPORT.md"

    public struct Reply: Codable, Sendable, Equatable {
        public var threadID: String
        public var title: String
        public var driver: String
        public var text: String
        /// When the agent gave it.
        public var at: Date

        public init(threadID: String, title: String, driver: String, text: String, at: Date) {
            self.threadID = threadID
            self.title = title
            self.driver = driver
            self.text = text
            self.at = at
        }
    }

    public struct File: Codable, Sendable, Equatable {
        /// As shown: the file name, behind its repository for a task of several (`api/REPORT.md`).
        public var name: String
        public var text: String
        /// Cut at `fileLimit`.
        public var truncated: Bool

        public init(name: String, text: String, truncated: Bool = false) {
            self.name = name
            self.text = text
            self.truncated = truncated
        }
    }

    public var version: Int
    public var taskID: String
    public var savedAt: Date
    /// Oldest first.
    public var replies: [Reply]
    public var files: [File]

    public init(taskID: String, savedAt: Date = .now, replies: [Reply] = [], files: [File] = []) {
        version = Self.currentVersion
        self.taskID = taskID
        self.savedAt = savedAt
        self.replies = replies.map(Self.bounded).sorted { $0.at < $1.at }
        self.files = files
    }

    public var isEmpty: Bool { replies.isEmpty && files.isEmpty }

    /// The latest reply: what the task came to.
    public var lastReply: Reply? { replies.max { $0.at < $1.at } }

    /// `self` with `newer` on top: a thread's newer reply replaces its older one, a file read again replaces the copy.
    /// A dismantle that resumes after a failure finds its threads already gone, and must not lose what the first run kept.
    public func merging(_ newer: TaskDeliverable) -> TaskDeliverable {
        var replies = Dictionary(self.replies.map { ($0.threadID, $0) }, uniquingKeysWith: { $1 })
        for reply in newer.replies where reply.at >= replies[reply.threadID]?.at ?? .distantPast {
            replies[reply.threadID] = reply
        }
        var files = self.files.filter { file in !newer.files.contains { $0.name == file.name } }
        files += newer.files
        return TaskDeliverable(taskID: taskID, savedAt: max(savedAt, newer.savedAt), replies: Array(replies.values), files: files)
    }

    /// `reply` cut to its last `replyLimit` bytes, behind a `…`.
    public static func bounded(_ reply: Reply) -> Reply {
        var copy = reply
        copy.text = tail(reply.text, bytes: replyLimit)
        return copy
    }

    /// The last `bytes` UTF-8 bytes of `text` behind a `…`, without a broken character.
    public static func tail(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > bytes else { return text }
        let kept = String(decoding: utf8.suffix(bytes - 3), as: UTF8.self).drop { $0 == "\u{FFFD}" }
        return "…" + kept
    }

    // MARK: Report files

    /// A folder a report may sit in: the task root, or one sandbox (`label` is its repository, `nil` for the root
    /// and for the sandbox of a task of one repository).
    public struct Folder: Sendable, Equatable {
        public var url: URL
        public var label: String?

        public init(url: URL, label: String?) {
            self.url = url
            self.label = label
        }
    }

    /// The report files found in `folders` under `names` (relative paths), each at most `limit` bytes, UTF-8 only.
    /// A name that climbs out of its folder — `..`, an absolute path, a symbolic link pointing elsewhere — is skipped:
    /// the name comes from the task's record, which an agent wrote. The same file reached twice is read once.
    public static func collectFiles(named names: [String], in folders: [Folder], limit: Int = fileLimit) -> [File] {
        var seen = Set<String>()
        var files: [File] = []
        var wanted: [String] = []
        for name in names {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !wanted.contains(name) { wanted.append(name) }
        }
        for folder in folders {
            let base = folder.url.standardizedFileURL.resolvingSymlinksInPath().path
            for name in wanted {
                guard !name.hasPrefix("/"), !name.hasPrefix("~"), !name.split(separator: "/").contains("..") else { continue }
                let resolved = folder.url.appending(path: name).standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(base + "/"), !seen.contains(resolved) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue,
                      let handle = FileHandle(forReadingAtPath: resolved) else { continue }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else { continue }
                let truncated = data.count > limit
                var bytes = truncated ? data.prefix(limit) : data
                var text = String(data: bytes, encoding: .utf8)
                // A cut inside a character (at most 3 of its bytes kept): drop them rather than refuse the file.
                for _ in 0..<3 where text == nil && truncated {
                    bytes = bytes.dropLast()
                    text = String(data: bytes, encoding: .utf8)
                }
                guard let text else { continue }
                seen.insert(resolved)
                files.append(File(name: folder.label.map { "\($0)/\(name)" } ?? name, text: text, truncated: truncated))
            }
        }
        return files
    }

    // MARK: Markdown

    /// The whole deliverable as one Markdown page: the report files first (written to be read), then each thread's
    /// last answer under its title.
    public var markdown: String {
        var parts: [String] = []
        let several = files.count + replies.count > 1
        for file in files {
            parts.append(several ? "# \(file.name)\n\n\(file.text)" : file.text)
            if file.truncated { parts.append("*Cut at \(Self.fileLimit / 1024) KB.*") }
        }
        for reply in replies {
            parts.append(several ? "# \(reply.title)\n\n\(reply.text)" : reply.text)
        }
        return parts.joined(separator: "\n\n")
    }
}

/// `<home>/tasks/deliverables/<id>.json`. Read and written whole; a file that does not decode is no deliverable — it
/// is history, and losing it never stops anything.
public enum TaskDeliverableStore {
    public static func directory(home: URL) -> URL {
        home.appending(path: "tasks", directoryHint: .isDirectory).appending(path: "deliverables", directoryHint: .isDirectory)
    }

    public static func url(home: URL, taskID: String) -> URL {
        directory(home: home).appending(path: "\(taskID).json", directoryHint: .notDirectory)
    }

    public static func load(home: URL, taskID: String) -> TaskDeliverable? {
        guard let deliverable = try? JSONStore.load(TaskDeliverable.self, from: url(home: home, taskID: taskID), fractionalSeconds: true),
              deliverable.version == TaskDeliverable.currentVersion else { return nil }
        return deliverable
    }

    /// Every deliverable kept, by task id.
    public static func loadAll(home: URL) -> [String: TaskDeliverable] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(home: home), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var all: [String: TaskDeliverable] = [:]
        for file in files where file.pathExtension == "json" {
            if let deliverable = load(home: home, taskID: file.deletingPathExtension().lastPathComponent) {
                all[deliverable.taskID] = deliverable
            }
        }
        return all
    }

    /// Adds `deliverable` to what is kept for its task already. Logged, never thrown: an archive must not fail on it.
    public static func keep(_ deliverable: TaskDeliverable, home: URL) {
        guard !deliverable.isEmpty else { return }
        let merged = load(home: home, taskID: deliverable.taskID)?.merging(deliverable) ?? deliverable
        do {
            try FileManager.default.createDirectory(at: directory(home: home), withIntermediateDirectories: true)
            try JSONStore.save(merged, to: url(home: home, taskID: deliverable.taskID), fractionalSeconds: true)
        } catch {
            Log.tasks.error("deliverable of task \(deliverable.taskID) not kept: \(String(describing: error))")
        }
    }
}
