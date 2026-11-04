import Foundation
import ScopeCore

/// The boxes of the sweep's confirmation. The defaults are the safe ones: reset the branches (the point of a sweep),
/// nothing on GitHub.
public struct TaskSweepOptions: Codable, Sendable, Equatable, Hashable {
    /// Put every primary worktree that stays back on the repository's base: the branch recreated there, local
    /// changes thrown away (saved first). Without it the worktrees that stay are left as they are.
    public var resetBranches: Bool
    /// Close the forgotten pull requests on GitHub too.
    public var closePullRequests: Bool
    /// Delete the task's branches on `origin`.
    public var deleteRemoteBranches: Bool

    public init(resetBranches: Bool = true, closePullRequests: Bool = false, deleteRemoteBranches: Bool = false) {
        self.resetBranches = resetBranches
        self.closePullRequests = closePullRequests
        self.deleteRemoteBranches = deleteRemoteBranches
    }

    /// Something leaves the machine: GitHub is told.
    public var touchesGitHub: Bool { closePullRequests || deleteRemoteBranches }

    private enum CodingKeys: String, CodingKey { case resetBranches, closePullRequests, deleteRemoteBranches }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetBranches = try container.decodeIfPresent(Bool.self, forKey: .resetBranches) ?? true
        closePullRequests = try container.decodeIfPresent(Bool.self, forKey: .closePullRequests) ?? false
        deleteRemoteBranches = try container.decodeIfPresent(Bool.self, forKey: .deleteRemoteBranches) ?? false
    }
}

/// What git says about one sandbox before a sweep: what the confirmation lists and what the sweep would lose.
public struct SandboxFacts: Codable, Sendable, Equatable {
    /// Commits on no remote and in no pull request (`GitClient.unpushedCommits`); `nil` when git could not say.
    public var unpushedCommits: Int?
    /// Files the working tree changed, untracked ones included (`git status --porcelain`).
    public var changedFiles: [String]

    public init(unpushedCommits: Int? = nil, changedFiles: [String] = []) {
        self.unpushedCommits = unpushedCommits
        self.changedFiles = changedFiles
    }

    /// The paths of `git status --porcelain -z`: `XY path` entries, a rename or copy followed by its old path.
    public static func changedFiles(porcelainZ output: String) -> [String] {
        var files: [String] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = fields.next() {
            guard entry.count > 3 else { continue }
            files.append(String(entry.dropFirst(3)))
            if entry.first == "R" || entry.first == "C" { _ = fields.next() }
        }
        return files
    }
}

/// What a sweep would do to a task, worked out from the record alone (and the facts git gave per sandbox): what the
/// confirmation shows and what `TaskManager.sweepTask` carries out. Pure, so the rules are under test.
///
/// The rules:
/// - every pull request is forgotten and marked ignored, so the next discovery does not bind it again;
/// - every secondary worktree goes, its branch kept;
/// - every repository added after the task was created goes, its branch kept. The repositories the task was created
///   with stay: the brief and the context file were written for them, and a task needs a sandbox for its threads.
///   When every repository left was added later (the originals removed one by one), the first one stays;
/// - with `resetBranches`, every primary worktree that stays is put back on its repository's base;
/// - the threads stay; the running ones are interrupted (the app's part).
/// Issue, topic, milestones and brief stay: they say what the task is for, not what it changed.
public struct TaskSweepPlan: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// The worktree is removed, its branch kept.
        case remove
        /// The branch is recreated on the base, the local changes thrown away.
        case reset
        /// Left as it is.
        case keep
    }

    public struct Sandbox: Codable, Sendable, Equatable {
        /// `TaskRepo.sandboxKey`.
        public var key: String
        public var repo: String
        public var branch: String
        public var path: String
        public var isSecondary: Bool
        public var action: Action
        public var unpushedCommits: Int?
        public var changedFiles: [String]

        public init(key: String, repo: String, branch: String, path: String, isSecondary: Bool, action: Action,
                    unpushedCommits: Int? = nil, changedFiles: [String] = []) {
            self.key = key
            self.repo = repo
            self.branch = branch
            self.path = path
            self.isSecondary = isSecondary
            self.action = action
            self.unpushedCommits = unpushedCommits
            self.changedFiles = changedFiles
        }

        /// What the sweep would lose here if nothing were saved: commits not on a remote, files not committed.
        public var losesWork: Bool { action != .keep && ((unpushedCommits ?? 0) > 0 || !changedFiles.isEmpty) }
    }

    public var options: TaskSweepOptions
    public var sandboxes: [Sandbox]
    /// The repositories leaving the task with all their worktrees.
    public var removedRepos: [String]
    public var pullRequests: [LinkedPullRequest]
    /// Why the sweep cannot run now (`nil` when it can).
    public var blocked: String?

    public init(options: TaskSweepOptions, sandboxes: [Sandbox], removedRepos: [String], pullRequests: [LinkedPullRequest],
                blocked: String? = nil) {
        self.options = options
        self.sandboxes = sandboxes
        self.removedRepos = removedRepos
        self.pullRequests = pullRequests
        self.blocked = blocked
    }

    public static func make(_ record: TaskRecord, facts: [String: SandboxFacts] = [:], options: TaskSweepOptions = .init()) -> TaskSweepPlan {
        let active = record.activeRepos
        // A task keeps at least one repository: the originals, else the first left.
        var removed = Set(active.filter { $0.addedAt != nil }.map(\.repoRelativePath))
        if removed.count == active.count, let first = active.first { removed.remove(first.repoRelativePath) }
        var sandboxes: [Sandbox] = []
        for repo in active {
            for sandbox in repo.sandboxes where sandbox.state == .active {
                let action: Action = if removed.contains(repo.repoRelativePath) || sandbox.isSecondary { .remove }
                    else if options.resetBranches { .reset } else { .keep }
                let fact = facts[sandbox.sandboxKey]
                sandboxes.append(Sandbox(key: sandbox.sandboxKey, repo: repo.repoRelativePath, branch: sandbox.branch,
                                         path: sandbox.sandboxPath, isSecondary: sandbox.isSecondary, action: action,
                                         unpushedCommits: fact?.unpushedCommits, changedFiles: fact?.changedFiles ?? []))
            }
        }
        var blocked: String?
        if record.isArchived {
            blocked = "the task is archived: restore it first"
        } else if let trying = record.trying.first(where: { session in
            sandboxes.contains { $0.repo == TaskRepo.normalize(session.repoRelativePath) && $0.action != .keep }
        }) {
            blocked = "your checkout of \(TaskRepo.displayName(trying.repoRelativePath)) is trying the task: put it back first"
        }
        return TaskSweepPlan(options: options, sandboxes: sandboxes, removedRepos: active.map(\.repoRelativePath).filter(removed.contains),
                             pullRequests: record.pullRequests, blocked: blocked)
    }

    /// Nothing to sweep: no pull request, no worktree to remove or reset.
    public var isEmpty: Bool { pullRequests.isEmpty && !sandboxes.contains { $0.action != .keep } }

    public var removed: [Sandbox] { sandboxes.filter { $0.action == .remove } }
    public var reset: [Sandbox] { sandboxes.filter { $0.action == .reset } }
    public var unpushedCommits: Int { sandboxes.filter { $0.action != .keep }.reduce(0) { $0 + ($1.unpushedCommits ?? 0) } }
    public var changedFiles: Int { sandboxes.filter { $0.action != .keep }.reduce(0) { $0 + $1.changedFiles.count } }

    /// The plan as the confirmation and `scope task sweep --dry-run` read it: one line per thing that goes.
    public func lines(scopeName: String) -> [String] {
        var lines: [String] = []
        func name(_ sandbox: Sandbox) -> String {
            let repo = sandbox.repo == "." ? scopeName : sandbox.repo
            return sandbox.isSecondary ? "\(repo) · \(sandbox.branch)" : repo
        }
        func loss(_ sandbox: Sandbox) -> String {
            var parts: [String] = []
            if let commits = sandbox.unpushedCommits, commits > 0 { parts.append("\(commits) unpushed \(commits == 1 ? "commit" : "commits")") }
            if !sandbox.changedFiles.isEmpty {
                parts.append("\(sandbox.changedFiles.count) modified \(sandbox.changedFiles.count == 1 ? "file" : "files")")
            }
            return parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
        }
        for link in pullRequests {
            let verb = options.closePullRequests && link.isOpen ? "closed on GitHub and forgotten" : "forgotten (stays open on GitHub)"
            lines.append("Pull request \(link.label) “\(link.title)”: \(verb)")
        }
        for repo in removedRepos {
            lines.append("Repository \(repo == "." ? scopeName : repo): removed from the task")
        }
        for sandbox in removed {
            lines.append("Worktree \(name(sandbox)) on \(sandbox.branch): removed, branch kept\(loss(sandbox))")
        }
        for sandbox in reset {
            lines.append("Worktree \(name(sandbox)): \(sandbox.branch) recreated on the base, local changes discarded\(loss(sandbox))")
        }
        if options.deleteRemoteBranches {
            let branches = Array(Set(sandboxes.filter { $0.action != .keep }.map(\.branch))).sorted()
            if !branches.isEmpty { lines.append("Remote branches deleted on origin: " + branches.joined(separator: ", ")) }
        }
        return lines
    }
}

/// What a sweep took away, kept on the record (`TaskRecord.lastSweep`) until it is undone or the next sweep replaces
/// it: enough to put every worktree, branch tip, change and pull request back.
public struct TaskSweepUndo: Codable, Sendable, Equatable {
    public struct Sandbox: Codable, Sendable, Equatable {
        public var key: String
        public var repo: String
        public var branch: String
        public var path: String
        public var isSecondary: Bool
        public var action: TaskSweepPlan.Action
        /// The branch's tip before the sweep.
        public var head: String
        /// Its upstream (`origin/feat/x`), when it had one: a reset unsets it, an undo sets it back.
        public var upstream: String?
        /// Under `refs/scope/salvage/`: the working tree as it was (a snapshot commit on top of `head`), or `head`
        /// itself when the sandbox was clean. Always written, so nothing the sweep moved hangs on the reflog alone.
        public var ref: String

        public init(key: String, repo: String, branch: String, path: String, isSecondary: Bool, action: TaskSweepPlan.Action,
                    head: String, upstream: String? = nil, ref: String) {
            self.key = key
            self.repo = repo
            self.branch = branch
            self.path = path
            self.isSecondary = isSecondary
            self.action = action
            self.head = head
            self.upstream = upstream
            self.ref = ref
        }
    }

    public var at: Date
    public var options: TaskSweepOptions
    public var sandboxes: [Sandbox]
    /// The repository entries removed whole (their worktrees with them), as they were.
    public var removedRepos: [TaskRepo]
    /// The secondary worktrees removed from repositories that stayed, by repository.
    public var removedWorktrees: [String: [TaskWorktree]]
    /// The pull requests and the ignore list before the sweep.
    public var pullRequests: [LinkedPullRequest]
    public var ignoredPullRequests: [URL]
    /// The checkpoint taken just before, when the sandboxes had changed since the last one.
    public var checkpoint: Int?

    public init(at: Date, options: TaskSweepOptions, sandboxes: [Sandbox], removedRepos: [TaskRepo], removedWorktrees: [String: [TaskWorktree]],
                pullRequests: [LinkedPullRequest], ignoredPullRequests: [URL], checkpoint: Int? = nil) {
        self.at = TaskRecord.roundedToMilliseconds(at)
        self.options = options
        self.sandboxes = sandboxes
        self.removedRepos = removedRepos
        self.removedWorktrees = removedWorktrees
        self.pullRequests = pullRequests
        self.ignoredPullRequests = ignoredPullRequests
        self.checkpoint = checkpoint
    }
}

/// The record side of the sweep and of each removal: pure, so what is removed, what is kept and what never comes back
/// are under test without git.
public enum TaskSweep {
    /// The record after `plan`: pull requests forgotten and ignored, worktrees and repositories out, `undo` kept.
    public static func apply(_ plan: TaskSweepPlan, to record: TaskRecord, undo: TaskSweepUndo) -> TaskRecord {
        var record = record
        let removedKeys = Set(plan.removed.map(\.key))
        record.repos.removeAll { plan.removedRepos.contains($0.repoRelativePath) }
        for index in record.repos.indices {
            let repo = record.repos[index]
            record.repos[index].worktrees.removeAll { worktree in removedKeys.contains(repo.sandbox(worktree).sandboxKey) }
        }
        for link in record.pullRequests { record.ignore(link.url) }
        // `keptOpenAfterMerge` stays: with no pull request left nothing archives the task, and an undo brings back
        // the merged one the user chose to keep the task open past.
        record.pullRequests = []
        record.lastSweep = undo
        return record
    }

    /// The record before the sweep `undo` recorded, kept what happened since: repositories and worktrees back in
    /// their place, pull requests and the ignore list as they were (links bound since kept too).
    public static func revert(_ undo: TaskSweepUndo, on record: TaskRecord) -> TaskRecord {
        var record = record
        for (path, worktrees) in undo.removedWorktrees {
            guard let index = record.repos.firstIndex(where: { $0.repoRelativePath == path }) else { continue }
            for worktree in worktrees where record.repos[index].worktree(onBranch: worktree.branch) == nil {
                record.repos[index].worktrees.append(worktree)
            }
        }
        for repo in undo.removedRepos where record.repo(at: repo.repoRelativePath) == nil {
            record.repos.append(repo)
        }
        let since = record.pullRequests.filter { link in !undo.pullRequests.contains { $0.url == link.url } }
        record.pullRequests = PullRequestSet.ordered(undo.pullRequests + since, repoOrder: record.repos.map(\.repoRelativePath))
        record.ignoredPullRequests = undo.ignoredPullRequests
        record.lastSweep = nil
        return record
    }

    /// The record without the repository `path` and its pull requests. Refused for the last repository, and for a repo
    /// scope task, which is its repository.
    public static func removingRepo(_ path: String, from record: TaskRecord) throws -> TaskRecord {
        let path = TaskRepo.normalize(path)
        guard !record.isMonoRepo else { throw TaskError.invalidRepoSelection("a repo scope task is its repository: archive or close it instead") }
        guard record.repo(at: path) != nil else { throw TaskError.repoNotFound(repo: path) }
        guard record.activeRepos.count > 1 || record.repo(at: path)?.state != .active else {
            throw TaskError.invalidRepoSelection("\(path) is the task's last repository: archive or close the task instead")
        }
        if record.trying.contains(where: { TaskRepo.normalize($0.repoRelativePath) == path }) {
            throw TaskError.invalidRepoSelection("your checkout of \(TaskRepo.displayName(path)) is trying the task: put it back first")
        }
        var record = record
        let first = record.repos.first?.repoRelativePath
        record.repos.removeAll { $0.repoRelativePath == path }
        record.pullRequests.removeAll { TaskRepo.normalize($0.repo ?? first ?? "") == path }
        return record
    }

    /// The record without the milestone `id`: its id, its 1-based number in the list, or its title.
    public static func removingMilestone(_ id: String, from record: TaskRecord) throws -> TaskRecord {
        guard var mission = record.mission else { throw TaskError.persistence("\(record.name) is not a mission") }
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = mission.milestones.firstIndex { $0.id == wanted }
            ?? Int(wanted).flatMap { number in mission.milestones.indices.contains(number - 1) ? number - 1 : nil }
            ?? mission.milestones.firstIndex { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }
        guard let index else { throw TaskError.persistence("no milestone \(id) on \(record.name)") }
        mission.milestones.remove(at: index)
        var record = record
        record.mission = mission
        return record
    }
}

extension TaskRecord {
    /// Forgets the pull request at `url`: out of the task, and ignored by the discoveries to come.
    public mutating func forgetPullRequest(_ url: URL) {
        pullRequests.removeAll { $0.url == url }
        ignore(url)
    }

    mutating func ignore(_ url: URL) {
        if !ignoredPullRequests.contains(url) { ignoredPullRequests.append(url) }
    }

    /// `links` found by a discovery, without the ones the user told Scope to forget.
    public func discovered(_ links: [LinkedPullRequest]) -> [LinkedPullRequest] {
        guard !ignoredPullRequests.isEmpty else { return links }
        let ignored = Set(ignoredPullRequests)
        return links.filter { !ignored.contains($0.url) }
    }

    /// Whether the pull request at `url` was forgotten on purpose.
    public func ignores(_ url: URL) -> Bool { ignoredPullRequests.contains(url) }
}
