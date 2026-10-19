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
    /// `name` of a repository path alone.
    public static func displayName(_ repoRelativePath: String) -> String {
        let path = normalize(repoRelativePath)
        return path == "." ? "." : URL(fileURLWithPath: path).lastPathComponent
    }
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

/// One pull request a task is bound to: created from it (`TaskManager.createForPullRequest`), linked after
/// "Create PR" in the Delta panel, or adopted by a refresh that found it on a branch of a sandbox. A task holds as
/// many as its work opened — one per repository, a stack, a docs PR beside a prototype — in `TaskRecord.pullRequests`.
/// Live state (checks, review) is not stored; `PullRequestsModel` has it.
public struct LinkedPullRequest: Codable, Sendable, Equatable, Hashable, Identifiable {
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
    /// When GitHub says it was opened, merged, closed: the ticks of the task's timeline. `nil` until a refresh asked.
    public var openedAt: Date?
    public var mergedAt: Date?
    public var closedAt: Date?
    /// The task repository it belongs to (`TaskRepo.repoRelativePath`): what tells `api#12` from `web#12`, and
    /// where its `gh` calls run. `nil` on links written before it was kept, which were all in the first repository.
    public var repo: String?
    /// Its head and base branches, as GitHub names them: a stacked pull request shows where it sits.
    public var headRefName: String?
    public var baseRefName: String?

    public init(number: Int, url: URL, title: String, headOwner: String? = nil, isCrossRepository: Bool = false,
                state: String? = nil, openedAt: Date? = nil, mergedAt: Date? = nil, closedAt: Date? = nil,
                repo: String? = nil, headRefName: String? = nil, baseRefName: String? = nil) {
        self.number = number
        self.url = url
        self.title = title
        self.headOwner = headOwner
        self.isCrossRepository = isCrossRepository
        self.state = state
        self.openedAt = openedAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.repo = repo.map(TaskRepo.normalize)
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }

    /// The URL is what tells two pull requests apart: numbers repeat across repositories.
    public var id: URL { url }

    /// `#123`
    public var label: String { "#\(number)" }

    /// `open` when GitHub never answered: a link is made of an open pull request.
    public var isOpen: Bool { (state ?? "open") == "open" }
    public var isMerged: Bool { state == "merged" }

    /// The link that binds a task to `pr`, in `repo` when known.
    public init(_ pr: PullRequest, repo: String? = nil) {
        self.init(number: pr.number, url: pr.url, title: pr.title, headOwner: pr.headOwner, isCrossRepository: pr.isCrossRepository,
                  state: pr.state.rawValue, openedAt: pr.createdAt, mergedAt: pr.mergedAt, closedAt: pr.closedAt,
                  repo: repo, headRefName: pr.headRefName, baseRefName: pr.baseRefName)
    }

    /// `pr` says something this link does not keep yet: a new title, state, branch or date.
    public func isStale(against pr: PullRequest) -> Bool {
        url == pr.url && (title != pr.title || state != pr.state.rawValue || openedAt != pr.createdAt
                          || mergedAt != pr.mergedAt || closedAt != pr.closedAt
                          || headRefName != pr.headRefName || baseRefName != pr.baseRefName)
    }

    /// This link with what `pr` says now, its repository kept.
    public func refreshed(with pr: PullRequest) -> LinkedPullRequest {
        LinkedPullRequest(pr, repo: repo)
    }
}

/// The user's checkout of one repository is running the task's branch (spec §4.5, "Try in my checkout"): what it
/// takes to put it back exactly. One per repository of the task at most; `endingAt` is set the moment a put back
/// starts, so one cut short by a quit is finished at the next launch.
public struct TrySession: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The repository, as `TaskRepo.repoRelativePath` names it.
    public var repoRelativePath: String
    /// Sha `HEAD` was at in the base checkout.
    public var previousHead: String
    /// The branch the base had checked out; `nil` when it was already detached.
    public var previousBranch: String?
    /// The stash holding the base's uncommitted changes; `nil` when the tree was clean.
    public var stashSHA: String?
    /// The commit of the task branch the base is detached onto (moves with Refresh).
    public var head: String
    public var since: Date
    /// A put back started and has not finished.
    public var endingAt: Date?

    public init(repoRelativePath: String, previousHead: String, previousBranch: String?, stashSHA: String?, head: String,
                since: Date = .now, endingAt: Date? = nil) {
        self.repoRelativePath = TaskRepo.normalize(repoRelativePath)
        self.previousHead = previousHead
        self.previousBranch = previousBranch
        self.stashSHA = stashSHA
        self.head = head
        self.since = TaskRecord.roundedToMilliseconds(since)
        self.endingAt = endingAt.map(TaskRecord.roundedToMilliseconds)
    }

    public var id: String { repoRelativePath }
    public var isEnding: Bool { endingAt != nil }
    /// Where the base goes back to, as the banner says it: the branch, or the short sha it was detached at.
    public var previousLabel: String { previousBranch ?? String(previousHead.prefix(7)) }
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
    /// Every pull request the task is bound to — the one it was opened from, the ones its threads opened, in every
    /// repository of the task — in the order `PullRequestSet.ordered` gives them. Empty until one is found.
    public var pullRequests: [LinkedPullRequest] = []
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
    /// Restored with a pull request: someone wants it open, so a merge no longer archives it (`MergedTaskArchive`).
    /// Set by `TaskManager.reopen`.
    public var keptOpenAfterMerge: Bool = false
    /// The file the task's work ends in, relative to the task root or a sandbox (`docs/study.md`): kept with the
    /// threads' last answers when the task is archived or closed (`TaskDeliverable`). `REPORT.md` is looked for anyway.
    public var deliverable: String?
    /// The user asked that the branch be left alone when main moves ("Don't rebase automatically"): Scope neither
    /// rebases it nor asks the agent to (`FollowMain`). Measuring and showing the lag goes on.
    public var holdBranch: Bool = false
    /// The head of the default branch Scope last acted on for this task — asked the agent, or rebased — so one move
    /// of main gets one action, whatever the refreshes in between (`FollowMain.decide`).
    public var followedMainHead: String?
    /// The GitHub issue the task was opened from, if any: its brief opens on it, and the pull request should close it.
    public var issue: LinkedIssue?
    /// The base checkouts running this task's branch right now (`TrySession`), one per repository at most. Empty
    /// when none is: the normal state, where the base is never touched.
    public var trying: [TrySession] = []
    /// One of N tasks run on the same brief (`task new --attempts`), until one is kept (`TaskAttempts`).
    public var attempt: TaskAttempt?
    /// Set on the task kept out of its attempts: the others were archived, this one took the brief's name back.
    public var attemptsKept: TaskAttemptsKept?
    /// A mission: the brief is a goal, reached through milestones the orchestrator names and Scope validates
    /// (`Mission`). `nil` for an ordinary task.
    public var mission: Mission?

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
        pullRequests: [LinkedPullRequest] = [],
        prompt: String? = nil,
        createdBy: String? = nil,
        portBase: Int? = nil,
        setup: TaskSetupRecord? = nil,
        cleanup: PendingCleanup? = nil,
        topic: String? = nil,
        parentTask: TaskID? = nil,
        origin: ThreadOrigin? = nil,
        deliverable: String? = nil,
        issue: LinkedIssue? = nil,
        attempt: TaskAttempt? = nil,
        mission: Mission? = nil
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
        self.pullRequests = PullRequestSet.ordered(pullRequests, repoOrder: repos.map(\.repoRelativePath))
        self.prompt = prompt
        self.createdBy = createdBy
        self.portBase = portBase
        self.setup = setup
        self.cleanup = cleanup
        self.topic = TaskTopic.normalize(topic)
        self.parentTask = parentTask
        self.origin = origin
        self.deliverable = deliverable
        self.issue = issue
        self.attempt = attempt
        self.mission = mission
    }

    public var fileName: String { "\(id.rawValue).json" }

    /// Dates are stored with millisecond precision; rounding at creation keeps an in-memory record
    /// equal to its reloaded copy.
    public static func roundedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
    public var isArchived: Bool { archivedAt != nil }
    /// The pull request a single button acts on when nothing picked one: the first open, else the first merged,
    /// else the first (`PullRequestSet.primary`). `nil` without any.
    public var primaryPullRequest: LinkedPullRequest? { PullRequestSet.primary(pullRequests) }
    /// `open`, `merged`, `closed` for the task as a whole (`PullRequestSet.aggregateState`), `nil` without a pull request.
    public var pullRequestState: String? { PullRequestSet.aggregateState(pullRequests.map(\.state)) }
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

    /// The sandboxes a thread started at `cwd` should see besides it (the driver profile's `addDir`): every
    /// active sandbox that neither is `cwd` nor contains it. Empty for a one-repository task, whose threads start
    /// in the sandbox; every sandbox for a thread at the root of a task of several repositories, where the
    /// repositories' own skills and instructions would otherwise stay one level down, out of the driver's sight.
    public func additionalDirectories(forCwd cwd: String) -> [String] {
        let cwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return activeRepos.map(\.sandboxURL.standardizedFileURL.path).filter { sandbox in
            cwd != sandbox && !cwd.hasPrefix(sandbox + "/")
        }
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
            pullRequests: pullRequests.map { .init(number: $0.number, url: $0.url, title: $0.title, state: $0.state, repo: $0.repo) },
            createdByAgent: createdByAgent, parentTask: parentTask?.rawValue
        )
    }

    /// `snapshot` with the time its agents worked and waited, from the turns of its threads.
    public func snapshot(lanes: [TimelineLaneSource], now: Date = .now) -> TaskSnapshot {
        var snapshot = snapshot
        guard lanes.contains(where: { !$0.turns.isEmpty || $0.openTurnSince != nil }) else { return snapshot }
        let totals = TaskTimeline.totals(createdAt: createdAt, archivedAt: archivedAt, now: now, lanes: lanes)
        snapshot.agentSeconds = totals.agent.rounded()
        snapshot.waitingSeconds = totals.waiting.rounded()
        return snapshot
    }

    /// Where `TaskDeliverable.collectFiles` looks: the task root, and every sandbox still there.
    public var deliverableFolders: [TaskDeliverable.Folder] {
        var folders = [TaskDeliverable.Folder(url: rootURL, label: nil)]
        let active = activeRepos
        for repo in active where repo.sandboxURL.standardizedFileURL != rootURL.standardizedFileURL {
            folders.append(.init(url: repo.sandboxURL, label: active.count == 1 ? nil : repo.repoRelativePath))
        }
        return folders
    }

    /// The report names to look for: the task's own, then `REPORT.md`.
    public var deliverableNames: [String] {
        [deliverable, TaskDeliverable.defaultFileName].compactMap { $0 }
    }

    /// The task's block of ports, once one was allocated.
    public var portBlock: PortBlock? { portBase.map { PortBlock(base: $0, size: PortAllocator.blockSize) } }

    /// The try session of a repository, if its base checkout is on this task's branch.
    public func trySession(for repoRelativePath: String) -> TrySession? {
        let key = TaskRepo.normalize(repoRelativePath)
        return trying.first { $0.repoRelativePath == key }
    }
    /// Whether the task is a mission (`Mission`).
    public var isMission: Bool { mission != nil }

    /// `notRun` for a record that never ran a setup.
    public var setupState: SetupState { setup?.state ?? .notRun }

    public func repo(at relativePath: String) -> TaskRepo? {
        let key = TaskRepo.normalize(relativePath)
        return repos.first { $0.repoRelativePath == key }
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, scopeID, scopeRoot, scopeSlug, scopeName, name, slug, branch, root, repos, createdAt, archivedAt, pullRequests, prompt
        case createdBy, portBase, setup, cleanup, topic, parentTask, origin, keptOpenAfterMerge, deliverable, issue
        case holdBranch, followedMainHead, trying, attempt, attemptsKept, mission
    }

    /// Keys read but no longer written.
    private enum LegacyCodingKeys: String, CodingKey {
        /// The one pull request a record held before it could hold several.
        case pullRequest
    }

    // Lenient decoding: identity, scope, slug, branch and root are required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
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
        let links = try container.decodeIfPresent([LinkedPullRequest].self, forKey: .pullRequests)
            ?? legacy.decodeIfPresent(LinkedPullRequest.self, forKey: .pullRequest).map { [$0] } ?? []
        pullRequests = PullRequestSet.ordered(links, repoOrder: repos.map(\.repoRelativePath))
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        portBase = try container.decodeIfPresent(Int.self, forKey: .portBase)
        setup = try container.decodeIfPresent(TaskSetupRecord.self, forKey: .setup)
        cleanup = try? container.decodeIfPresent(PendingCleanup.self, forKey: .cleanup)
        topic = TaskTopic.normalize(try? container.decodeIfPresent(String.self, forKey: .topic))
        parentTask = (try? container.decodeIfPresent(TaskID.self, forKey: .parentTask)) ?? nil
        origin = (try? container.decodeIfPresent(ThreadOrigin.self, forKey: .origin)) ?? nil
        keptOpenAfterMerge = (try? container.decodeIfPresent(Bool.self, forKey: .keptOpenAfterMerge)) ?? false
        deliverable = (try? container.decodeIfPresent(String.self, forKey: .deliverable)) ?? nil
        holdBranch = (try? container.decodeIfPresent(Bool.self, forKey: .holdBranch)) ?? false
        followedMainHead = (try? container.decodeIfPresent(String.self, forKey: .followedMainHead)) ?? nil
        issue = (try? container.decodeIfPresent(LinkedIssue.self, forKey: .issue)) ?? nil
        trying = (try? container.decodeIfPresent([TrySession].self, forKey: .trying)) ?? []
        attempt = (try? container.decodeIfPresent(TaskAttempt.self, forKey: .attempt)) ?? nil
        attemptsKept = (try? container.decodeIfPresent(TaskAttemptsKept.self, forKey: .attemptsKept)) ?? nil
        mission = (try? container.decodeIfPresent(Mission.self, forKey: .mission)) ?? nil
    }
}
