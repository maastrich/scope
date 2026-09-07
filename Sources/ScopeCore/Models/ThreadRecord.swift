import Foundation

/// What the thread's working directory refers to. Serialised as `{ "scopeRoot" : {} }`,
/// `{ "repoBase" : { "relativePath" : "api" } }` or `{ "task" : { "slug" : "auth-refresh" } }`.
public enum ThreadCwdKind: Codable, Sendable, Equatable, Hashable {
    case scopeRoot
    /// "Open a shell here" on a base (spec §4.5).
    case repoBase(relativePath: String)
    /// A task sandbox root (M2).
    case task(slug: String)
}

/// One `threads/<id>.json` document: everything needed to show, relaunch or resume a thread
/// after an app restart.
///
/// Written on create, on every launch, on every exit and when `resumeID` changes; deleted when the
/// thread is closed.
public struct ThreadRecord: Codable, Sendable, Equatable, Identifiable {
    /// Schema version written by this build. Newer documents are refused, never overwritten.
    public static let currentVersion = 1

    public var version: Int
    public var id: ThreadID
    public var scopeID: ScopeID
    /// Scope root path at creation; lets `ThreadRestorer` rebind the record by realpath when the
    /// scope was removed and declared again with a new id.
    public var scopeRoot: String
    public var driverID: String
    /// `"Shell · acme"`
    public var title: String
    /// Absolute path used at launch.
    public var cwd: String
    public var cwdKind: ThreadCwdKind
    /// Raw id of the task the thread belongs to (M2); `nil` for scope-level threads. Kept as a string so
    /// `ScopeCore` does not depend on `ScopeTasks`; old records without the key still decode.
    public var taskID: String?
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    public var lastExit: ExitStatus?
    public var launchCount: Int
    /// Driver session id captured by an adapter (M1/M4); `nil` = cannot resume.
    public var resumeID: String?
    /// Last known state; normalized to `.idle` when loaded after a restart (see `ThreadRecordStore.loadAll`).
    public var lastState: ThreadState?
    /// Path of the thread's output log (M1); unused in M0.
    public var log: String?

    public init(
        id: ThreadID = .generate(),
        scopeID: ScopeID,
        scopeRoot: String,
        driverID: String,
        title: String,
        cwd: String,
        cwdKind: ThreadCwdKind,
        taskID: String? = nil,
        createdAt: Date = .now
    ) {
        version = ThreadRecord.currentVersion
        self.id = id
        self.scopeID = scopeID
        self.scopeRoot = scopeRoot
        self.driverID = driverID
        self.title = title
        self.cwd = cwd
        self.cwdKind = cwdKind
        self.taskID = taskID
        self.createdAt = createdAt
        lastLaunchedAt = nil
        lastExit = nil
        launchCount = 0
        resumeID = nil
        lastState = nil
        log = nil
    }

    /// `"<id>.json"`
    public var fileName: String { "\(id.rawValue).json" }

    private enum CodingKeys: String, CodingKey {
        case version, id, scopeID, scopeRoot, driverID, title, cwd, cwdKind, taskID, createdAt
        case lastLaunchedAt, lastExit, launchCount, resumeID, lastState, log
    }

    // Lenient decoding: only identity, driver and cwd are required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(ThreadID.self, forKey: .id)
        scopeID = try container.decode(ScopeID.self, forKey: .scopeID)
        scopeRoot = try container.decodeIfPresent(String.self, forKey: .scopeRoot) ?? ""
        driverID = try container.decode(String.self, forKey: .driverID)
        cwd = try container.decode(String.self, forKey: .cwd)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? driverID
        cwdKind = try container.decodeIfPresent(ThreadCwdKind.self, forKey: .cwdKind) ?? .scopeRoot
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        lastExit = try container.decodeIfPresent(ExitStatus.self, forKey: .lastExit)
        launchCount = try container.decodeIfPresent(Int.self, forKey: .launchCount) ?? 0
        resumeID = try container.decodeIfPresent(String.self, forKey: .resumeID)
        lastState = try container.decodeIfPresent(ThreadState.self, forKey: .lastState)
        log = try container.decodeIfPresent(String.self, forKey: .log)
    }
}
