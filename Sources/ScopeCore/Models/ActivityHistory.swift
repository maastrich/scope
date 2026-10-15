import Foundation

/// What a task looked like when Scope last held it: enough to say what the work was, how it ended and where it went,
/// without the setup log or anything that only matters while the task is open.
///
/// Built from a live `TaskRecord` (`ScopeTasks`) when a summary is asked for, and written to the history when the
/// record is deleted — a closed task leaves nothing else behind.
public struct TaskSnapshot: Codable, Sendable, Equatable {
    /// The pull request the task was bound to, with the last state Scope saw on GitHub.
    public struct PullRequest: Codable, Sendable, Equatable {
        public var number: Int
        public var url: URL
        public var title: String
        /// `open`, `merged` or `closed` as last observed; `nil` when Scope never looked after binding it.
        public var state: String?

        public init(number: Int, url: URL, title: String, state: String? = nil) {
            self.number = number
            self.url = url
            self.title = title
            self.state = state
        }
    }

    public var id: String
    public var name: String
    public var slug: String
    public var scopeID: String
    public var scopeSlug: String
    public var scopeName: String
    public var branch: String
    public var topic: String?
    /// Repository paths relative to the scope root.
    public var repos: [String]
    public var createdAt: Date
    public var archivedAt: Date?
    /// The brief the task was created from; capped at `promptLimit` in the history.
    public var prompt: String?
    public var pullRequest: PullRequest?
    /// An agent asked for the task (`TaskRecord.createdByAgent`).
    public var createdByAgent: Bool
    public var parentTask: String?

    /// A brief longer than this is cut before it goes to the history: the summary only ever shows its first lines,
    /// and the detail of one task is still readable at this length.
    public static let promptLimit = 8_000

    public init(id: String, name: String, slug: String, scopeID: String, scopeSlug: String, scopeName: String,
                branch: String, topic: String? = nil, repos: [String] = [], createdAt: Date, archivedAt: Date? = nil,
                prompt: String? = nil, pullRequest: PullRequest? = nil, createdByAgent: Bool = false,
                parentTask: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.scopeID = scopeID
        self.scopeSlug = scopeSlug
        self.scopeName = scopeName
        self.branch = branch
        self.topic = topic
        self.repos = repos
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.prompt = prompt
        self.pullRequest = pullRequest
        self.createdByAgent = createdByAgent
        self.parentTask = parentTask
    }

    /// The copy kept in the history: the prompt cut at `promptLimit`.
    public var capped: TaskSnapshot {
        var copy = self
        if let prompt, prompt.count > Self.promptLimit { copy.prompt = String(prompt.prefix(Self.promptLimit)) + "…" }
        return copy
    }
}

/// What a thread looked like when Scope last held it. What was said in it is not here: Scope keeps a terminal's
/// scrollback in memory only.
public struct ThreadSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var driverID: String
    public var scopeID: String
    public var scopeRoot: String
    /// Raw id of the task it belonged to, if any.
    public var taskID: String?
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    public var launchCount: Int
    /// The driver's own session id (`ThreadRecord.resumeID`): where the driver, not Scope, may keep a transcript.
    public var session: String?
    /// An agent opened it.
    public var openedByAgent: Bool
    /// `orchestrator` or `terminal` for the two threads Scope keeps in every scope.
    public var resident: String?

    public init(id: String, title: String, driverID: String, scopeID: String, scopeRoot: String, taskID: String? = nil,
                createdAt: Date, lastLaunchedAt: Date? = nil, launchCount: Int = 0, session: String? = nil,
                openedByAgent: Bool = false, resident: String? = nil) {
        self.id = id
        self.title = title
        self.driverID = driverID
        self.scopeID = scopeID
        self.scopeRoot = scopeRoot
        self.taskID = taskID
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.launchCount = launchCount
        self.session = session
        self.openedByAgent = openedByAgent
        self.resident = resident
    }
}

extension ThreadRecord {
    public var snapshot: ThreadSnapshot {
        ThreadSnapshot(id: id.rawValue, title: title, driverID: driverID, scopeID: scopeID.rawValue, scopeRoot: scopeRoot,
                       taskID: taskID, createdAt: createdAt, lastLaunchedAt: lastLaunchedAt, launchCount: launchCount,
                       session: resumeID, openedByAgent: resolvedOrigin.openedByAgent, resident: resident?.rawValue)
    }
}

/// One line of `<home>/history.jsonl`: a record Scope deleted, as it was just before.
///
/// Task and thread records are the source of truth while they exist; this only keeps what their deletion would
/// otherwise erase — a closed task, a closed thread — so a summary of past work can still name it. It is not a
/// second model of the same things: nothing reads it back into the app.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case taskClosed = "task.closed"
        case threadClosed = "thread.closed"
    }

    public var kind: Kind
    public var at: Date
    public var task: TaskSnapshot?
    public var thread: ThreadSnapshot?

    public static func taskClosed(_ task: TaskSnapshot, at: Date = .now) -> HistoryEntry {
        HistoryEntry(kind: .taskClosed, at: at, task: task.capped, thread: nil)
    }

    public static func threadClosed(_ thread: ThreadSnapshot, at: Date = .now) -> HistoryEntry {
        HistoryEntry(kind: .threadClosed, at: at, task: nil, thread: thread)
    }
}

/// `<home>/history.jsonl`, append-only, one `HistoryEntry` per line.
///
/// Appends go through `O_APPEND`, so the task store and the thread store (two actors) never interleave inside a
/// line. A line that does not decode — cut by a crash, written by a newer build — is skipped, never repaired, and the
/// next append starts after it rather than on it.
public enum ActivityHistory {
    public static func url(home: URL) -> URL {
        home.appending(path: "history.jsonl", directoryHint: .notDirectory)
    }

    /// Adds `entry` at the end of the history. Logged, never thrown: losing a line must not stop a close.
    public static func append(_ entry: HistoryEntry, home: URL) {
        let file = url(home: home)
        do {
            let encoder = JSONStore.makeEncoder(fractionalSeconds: true)
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(entry)
            line.append(UInt8(ascii: "\n"))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let descriptor = open(file.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }
            // A line cut by a crash would swallow this one: start on a line of its own.
            let size = lseek(descriptor, 0, SEEK_END)
            var last: UInt8 = 0
            if size > 0, pread(descriptor, &last, 1, size - 1) == 1, last != UInt8(ascii: "\n") {
                line.insert(UInt8(ascii: "\n"), at: 0)
            }
            let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            Log.app.error("history append failed: \(String(describing: error))")
        }
    }

    /// Every entry that decodes, in file order.
    public static func load(home: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url(home: home)) else { return [] }
        let decoder = JSONStore.makeDecoder(fractionalSeconds: true)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
    }
}
