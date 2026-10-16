import Foundation
import ScopeCore
import ScopeGit

/// Identity of a task: 12 lowercase hex characters, used verbatim as `tasks/<id>.json`.
public struct TaskID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    /// `nil` unless `rawValue` matches `^[0-9a-f]{12}$`.
    public init?(rawValue: String) {
        guard ThreadID.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// A fresh random identifier.
    public static func generate() -> TaskID {
        TaskID(rawValue: ThreadID.generate().rawValue)!
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = TaskID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid task id \"\(raw)\"")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One repository of a task and its sandbox (spec §2: *Sandbox*).
public struct TaskRepo: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable, Hashable {
        /// The worktree exists (or should exist) on disk.
        case active
        /// The worktree was removed, the branch kept (`TaskManager.archive`).
        case archived
    }

    /// Path of the base checkout relative to the scope root; `"."` when the scope itself is the repo.
    public var repoRelativePath: String
    /// Absolute path of the worktree.
    public var sandboxPath: String
    /// Branch checked out in the sandbox (the task branch).
    public var branch: String
    public var state: State
    /// `true` when the task created the branch, `false` when it checked out one that already existed, `nil`
    /// on records written before the flag existed. What tells an undo whether deleting the branch is safe.
    public var branchCreated: Bool?
    /// The commit holding what the sandbox had not committed when it was removed (`TaskManager.dismantle`),
    /// under `refs/scope/salvage/` in the base checkout; `nil` when it was clean.
    public var salvageRef: String?

    public init(repoRelativePath: String, sandboxPath: String, branch: String, state: State = .active,
                branchCreated: Bool? = nil, salvageRef: String? = nil) {
        self.repoRelativePath = TaskRepo.normalize(repoRelativePath)
        self.sandboxPath = sandboxPath
        self.branch = branch
        self.state = state
        self.branchCreated = branchCreated
        self.salvageRef = salvageRef
    }

    public var id: String { repoRelativePath }
    /// The scope folder is the repository itself (repo scope): the sandbox *is* the task root.
    public var isScopeRoot: Bool { repoRelativePath == "." }
    /// Display name: last path component, or the scope name for `"."`.
    public var name: String { isScopeRoot ? "." : URL(fileURLWithPath: repoRelativePath).lastPathComponent }
    public var sandboxURL: URL { URL(fileURLWithPath: sandboxPath, isDirectory: true) }

    /// `""`, `"/"`, `"./"` → `"."`; strips leading `./` and trailing `/`.
    public static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasSuffix("/") { p.removeLast() }
        while p.hasPrefix("/") { p.removeFirst() }
        return p.isEmpty ? "." : p
    }
}

/// The pull request a task is bound to: created from it (`TaskManager.createForPullRequest`) or linked
/// after "Create PR" in the Delta panel. Live state (checks, review) is not stored; `PullRequestsModel` has it.
public struct LinkedPullRequest: Codable, Sendable, Equatable, Hashable {
    public var number: Int
    public var url: URL
    public var title: String
    /// Owner of the head repository (the fork owner for a cross-repository PR).
    public var headOwner: String?
    /// The head lives in a fork: the sandbox branch tracks `pull/<n>/head`, not a branch of `origin`.
    public var isCrossRepository: Bool
    /// `open`, `merged` or `closed`, as GitHub last answered while the task was open: what tells a delivered task
    /// from a dropped one once it is archived and nobody asks GitHub any more. `nil` on links never refreshed.
    public var state: String?

    public init(number: Int, url: URL, title: String, headOwner: String? = nil, isCrossRepository: Bool = false,
                state: String? = nil) {
        self.number = number
        self.url = url
        self.title = title
        self.headOwner = headOwner
        self.isCrossRepository = isCrossRepository
        self.state = state
    }

    /// `#123`
    public var label: String { "#\(number)" }

    /// The link that binds a task to `pr`.
    public init(_ pr: PullRequest) {
        self.init(number: pr.number, url: pr.url, title: pr.title, headOwner: pr.headOwner, isCrossRepository: pr.isCrossRepository,
                  state: pr.state.rawValue)
    }
}

/// One `tasks/<id>.json` document (spec §4.3).
public struct TaskRecord: Codable, Sendable, Equatable, Identifiable {
    /// Schema version written by this build. Newer documents are refused, never overwritten.
    public static let currentVersion = 1

    public var version: Int
    public var id: TaskID
    public var scopeID: ScopeID
    /// Scope root path at creation (locates the base checkouts).
    public var scopeRoot: String
    /// Scope slug at creation (names `sandboxes/<scope-slug>/`).
    public var scopeSlug: String
    /// Scope display name at creation (shown in `AGENTS.md`).
    public var scopeName: String
    /// Display name as typed.
    public var name: String
    /// Unique within the scope; names the task root and the branch.
    public var slug: String
    /// The task branch, proposed by the driver (or derived from the prompt) when the task was created;
    /// follows the repo's own naming convention, never a `scope/` prefix.
    public var branch: String
    /// Absolute path of the task root (`<home>/sandboxes/<scope-slug>/<task-slug>/`).
    public var root: String
    public var repos: [TaskRepo]
    public var createdAt: Date
    /// Set by `TaskManager.archive`.
    public var archivedAt: Date?
    /// The pull request this task was opened from or linked to, if any.
    public var pullRequest: LinkedPullRequest?
    /// The initial request the task was created from (New Task sheet); shown in the sidebar and as the
    /// "Goal" of `AGENTS.md`, and given to the first thread as its opening prompt.
    public var prompt: String?
    /// Who asked for the task: `nil` (the user, in the app) or the control client that requested it
    /// (`scope-cli/0.4.0`). Written so the sidebar and `scope list` can say what an agent created.
    public var createdBy: String?
    /// First of the task's block of `PortAllocator.blockSize` ports (`SCOPE_PORT`); `nil` on records written before
    /// ports were handed out, until the next launch allocates one.
    public var portBase: Int?
    /// The setup of the sandboxes, `nil` on records written before setup existed.
    public var setup: TaskSetupRecord?
    /// An archive or close that started and has not finished (`TaskManager.dismantle`).
    public var cleanup: PendingCleanup?
    /// The topic the task is filed under in the sidebar (`TaskTopic`), shared with the tasks of the same piece of work.
    public var topic: String?
    /// The task whose agent created this one, when one did.
    public var parentTask: TaskID?
    /// Who asked for the task, as recorded for its first thread: what tells an agent's task from the user's when the
    /// budgets count them. `nil` on records from before it existed and on tasks the user made in the app.
    public var origin: ThreadOrigin?
    /// Restored after its pull request merged: the user wants it open, so a merge no longer archives it
    /// (`MergedTaskArchive`). Set by `TaskManager.reopen`.
    public var keptOpenAfterMerge: Bool = false

    public init(
        id: TaskID = .generate(),
        scopeID: ScopeID,
        scopeRoot: String,
        scopeSlug: String,
        scopeName: String? = nil,
        name: String,
        slug: String,
        branch: String,
        root: String,
        repos: [TaskRepo] = [],
        createdAt: Date = .now,
        archivedAt: Date? = nil,
        pullRequest: LinkedPullRequest? = nil,
        prompt: String? = nil,
        createdBy: String? = nil,
        portBase: Int? = nil,
        setup: TaskSetupRecord? = nil,
        cleanup: PendingCleanup? = nil,
        topic: String? = nil,
        parentTask: TaskID? = nil,
        origin: ThreadOrigin? = nil
    ) {
        version = TaskRecord.currentVersion
        self.id = id
        self.scopeID = scopeID
        self.scopeRoot = scopeRoot
        self.scopeSlug = scopeSlug
        self.scopeName = scopeName ?? scopeSlug
        self.name = name
        self.slug = slug
        self.branch = branch
        self.root = root
        self.repos = repos
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.pullRequest = pullRequest
        self.prompt = prompt
        self.createdBy = createdBy
        self.portBase = portBase
        self.setup = setup
        self.cleanup = cleanup
        self.topic = TaskTopic.normalize(topic)
        self.parentTask = parentTask
        self.origin = origin
    }

    public var fileName: String { "\(id.rawValue).json" }

    /// Dates are stored with millisecond precision; rounding at creation keeps an in-memory record
    /// equal to its reloaded copy.
    public static func roundedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    public var isArchived: Bool { archivedAt != nil }
    public var activeRepos: [TaskRepo] { repos.filter { $0.state == .active } }
    /// Repo scope: the single repo is the scope folder itself, so the task root is the sandbox.
    public var isMonoRepo: Bool { repos.count == 1 && repos[0].isScopeRoot }

    /// `<root>/<slug>.code-workspace`
    public var workspaceURL: URL { rootURL.appending(path: "\(slug).code-workspace", directoryHint: .notDirectory) }
    /// `<thread cwd>/AGENTS.md` — the pivot name, for callers that only need the default one.
    public var contextFileURL: URL { contextFileURL(named: TaskRecord.pivotContextFile) }

    /// The context file a driver reading `name` would find: it sits where the task's threads start, which
    /// is the sandbox for a one-repository task and the task root otherwise. A file written anywhere else
    /// is a file the driver never opens.
    public func contextFileURL(named name: String) -> URL {
        threadCwd.appending(path: name, directoryHint: .notDirectory)
    }

    /// The name every driver understands, written even when no profile asks for it.
    public static let pivotContextFile = "AGENTS.md"

    /// Working directory of a thread attached to this task (spec §4.3): the sandbox itself when
    /// the task has exactly one active repo (drivers expect a git root), the task root otherwise.
    public var threadCwd: URL {
        let active = activeRepos
        if active.count == 1 { return active[0].sandboxURL }
        return rootURL
    }

    /// The active sandbox `path` is in (or is), so a thread that wandered into a subfolder still names its
    /// checkout. nil at the task root of a task of several repositories, and outside the task.
    public func sandbox(containing path: String) -> TaskRepo? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return activeRepos
            .filter { repo in
                let sandbox = repo.sandboxURL.standardizedFileURL.path
                return path == sandbox || path.hasPrefix(sandbox + "/")
            }
            .max { $0.sandboxPath.count < $1.sandboxPath.count }
    }

    /// Variables injected into the task's threads: `SCOPE_TASK` (slug), `SCOPE_TASK_ROOT` (task root path) and,
    /// once allocated, `SCOPE_PORT` (the first of the task's ports).
    public var environment: [String: String] {
        var variables = ["SCOPE_TASK": slug, "SCOPE_TASK_ROOT": root]
        if let portBase { variables["SCOPE_PORT"] = String(portBase) }
        return variables
    }

    /// Whether an agent asked for the task: what the agents' budget counts. A record from before origins were kept
    /// says so through its client, which only `scope mcp` marks as an agent's for certain.
    public var createdByAgent: Bool {
        if let origin { return origin.openedByAgent }
        return (createdBy ?? "").hasPrefix(ThreadOrigin.mcpClientPrefix)
    }

    /// What a summary of past work needs from the task, and what the history keeps of it once it is closed.
    public var snapshot: TaskSnapshot {
        TaskSnapshot(
            id: id.rawValue, name: name, slug: slug, scopeID: scopeID.rawValue, scopeSlug: scopeSlug, scopeName: scopeName,
            branch: branch, topic: topic, repos: repos.map(\.repoRelativePath), createdAt: createdAt, archivedAt: archivedAt,
            prompt: prompt,
            pullRequest: pullRequest.map { .init(number: $0.number, url: $0.url, title: $0.title, state: $0.state) },
            createdByAgent: createdByAgent, parentTask: parentTask?.rawValue
        )
    }

    /// `notRun` for a record that never ran a setup.
    public var setupState: SetupState { setup?.state ?? .notRun }

    public func repo(at relativePath: String) -> TaskRepo? {
        let key = TaskRepo.normalize(relativePath)
        return repos.first { $0.repoRelativePath == key }
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, scopeID, scopeRoot, scopeSlug, scopeName, name, slug, branch, root, repos, createdAt, archivedAt, pullRequest, prompt
        case createdBy, portBase, setup, cleanup, topic, parentTask, origin, keptOpenAfterMerge
    }

    // Lenient decoding: identity, scope, slug, branch and root are required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(TaskID.self, forKey: .id)
        scopeID = try container.decode(ScopeID.self, forKey: .scopeID)
        scopeRoot = try container.decodeIfPresent(String.self, forKey: .scopeRoot) ?? ""
        scopeSlug = try container.decodeIfPresent(String.self, forKey: .scopeSlug) ?? ""
        scopeName = try container.decodeIfPresent(String.self, forKey: .scopeName) ?? scopeSlug
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? slug
        branch = try container.decode(String.self, forKey: .branch)
        root = try container.decode(String.self, forKey: .root)
        repos = try container.decodeIfPresent([TaskRepo].self, forKey: .repos) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        pullRequest = try container.decodeIfPresent(LinkedPullRequest.self, forKey: .pullRequest)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        portBase = try container.decodeIfPresent(Int.self, forKey: .portBase)
        setup = try container.decodeIfPresent(TaskSetupRecord.self, forKey: .setup)
        cleanup = try? container.decodeIfPresent(PendingCleanup.self, forKey: .cleanup)
        topic = TaskTopic.normalize(try? container.decodeIfPresent(String.self, forKey: .topic))
        parentTask = (try? container.decodeIfPresent(TaskID.self, forKey: .parentTask)) ?? nil
        origin = (try? container.decodeIfPresent(ThreadOrigin.self, forKey: .origin)) ?? nil
        keptOpenAfterMerge = (try? container.decodeIfPresent(Bool.self, forKey: .keptOpenAfterMerge)) ?? false
    }
}
