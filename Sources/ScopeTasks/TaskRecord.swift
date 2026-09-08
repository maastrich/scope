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

    public init(repoRelativePath: String, sandboxPath: String, branch: String, state: State = .active) {
        self.repoRelativePath = TaskRepo.normalize(repoRelativePath)
        self.sandboxPath = sandboxPath
        self.branch = branch
        self.state = state
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

    public init(number: Int, url: URL, title: String, headOwner: String? = nil, isCrossRepository: Bool = false) {
        self.number = number
        self.url = url
        self.title = title
        self.headOwner = headOwner
        self.isCrossRepository = isCrossRepository
    }

    /// `#123`
    public var label: String { "#\(number)" }

    /// The link that binds a task to `pr`.
    public init(_ pr: PullRequest) {
        self.init(number: pr.number, url: pr.url, title: pr.title, headOwner: pr.headOwner, isCrossRepository: pr.isCrossRepository)
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
        prompt: String? = nil
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
    /// `<root>/AGENTS.md`
    public var contextFileURL: URL { rootURL.appending(path: "AGENTS.md", directoryHint: .notDirectory) }

    /// Working directory of a thread attached to this task (spec §4.3): the sandbox itself when
    /// the task has exactly one active repo (drivers expect a git root), the task root otherwise.
    public var threadCwd: URL {
        let active = activeRepos
        if active.count == 1 { return active[0].sandboxURL }
        return rootURL
    }

    /// Variables injected into the task's threads: `SCOPE_TASK` (slug) and `SCOPE_TASK_ROOT` (task root path).
    public var environment: [String: String] {
        ["SCOPE_TASK": slug, "SCOPE_TASK_ROOT": root]
    }

    public func repo(at relativePath: String) -> TaskRepo? {
        let key = TaskRepo.normalize(relativePath)
        return repos.first { $0.repoRelativePath == key }
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, scopeID, scopeRoot, scopeSlug, scopeName, name, slug, branch, root, repos, createdAt, archivedAt, pullRequest, prompt
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
    }
}
