import Foundation
import ScopeCore

/// What the user was looking at when they pinned a repository in the Base panel. A pin belongs to the context it
/// was made in — the task, the loose thread, or the scope when neither is selected — so it does not follow the
/// user into the next task, which is what a pin kept per scope did.
public enum BaseContext: Hashable, Sendable {
    case task(TaskID)
    case thread(ThreadID)
    case scope(ScopeID)

    /// `task:<id>`, `thread:<id>`, `scope:<id>`: the key the pins are stored under in the UI state.
    public var key: String {
        switch self {
        case .task(let id): "task:\(id.rawValue)"
        case .thread(let id): "thread:\(id.rawValue)"
        case .scope(let id): "scope:\(id.rawValue)"
        }
    }
}

/// Why the Base panel is on the repository it shows; the panel says it in a sentence.
public enum BaseSubjectReason: String, Sendable, Equatable {
    /// The user picked it in this context.
    case pinned
    /// It is the repo row selected in the sidebar.
    case selection
    /// The shown thread's directory is inside it (its base checkout, or the task's sandbox of it).
    case thread
    /// The file open in the Delta panel belongs to it.
    case delta
    /// It is the first repository of the selected task.
    case task
    /// It is the last repository the panel showed in this scope.
    case recent
    /// Nothing else applied: the first repository of the scope.
    case first
}

/// The repository the Base panel shows, and why.
public struct BaseSubject: Sendable, Equatable {
    /// Path relative to the scope root, normalized like `TaskRepo.repoRelativePath` (`"."` for a repo scope).
    public var repo: String
    public var reason: BaseSubjectReason

    public init(repo: String, reason: BaseSubjectReason) {
        self.repo = repo
        self.reason = reason
    }
}

/// Everything the choice depends on, as plain values so the rule can be tested without the app.
public struct BaseSubjectInput: Sendable {
    /// Absolute path of the scope folder.
    public var scopeRoot: String
    /// The scope's repositories, relative to the root, in sidebar order.
    public var repos: [String]
    /// The repository pinned in the current context, if any.
    public var pin: String?
    /// The repo row selected in the sidebar, if the selection is one.
    public var selectedRepo: String?
    /// Where the shown thread is: the directory its shell reported, else the one it started in.
    public var threadDirectory: String?
    /// The active repositories of the selected task (empty without a task).
    public var taskRepos: [TaskRepo]
    /// The repository of the file open in the Delta panel, when Delta is on the selected task.
    public var deltaFocus: String?
    /// The repository the panel last showed in this scope.
    public var recent: String?

    public init(scopeRoot: String, repos: [String], pin: String? = nil, selectedRepo: String? = nil,
                threadDirectory: String? = nil, taskRepos: [TaskRepo] = [], deltaFocus: String? = nil,
                recent: String? = nil) {
        self.scopeRoot = scopeRoot
        self.repos = repos
        self.pin = pin
        self.selectedRepo = selectedRepo
        self.threadDirectory = threadDirectory
        self.taskRepos = taskRepos
        self.deltaFocus = deltaFocus
        self.recent = recent
    }
}

public enum BaseSubjectResolver {
    /// First match wins: the pin of the context, the selected repo row, the repository the thread is working in,
    /// the one Delta is on, the task's first, the scope's most recent, the scope's first. A candidate the scope
    /// no longer has is skipped, so a stale pin or a removed repository falls through instead of showing nothing.
    public static func resolve(_ input: BaseSubjectInput) -> BaseSubject? {
        let repos = input.repos.map(TaskRepo.normalize)
        func known(_ path: String?) -> String? {
            guard let path else { return nil }
            let key = TaskRepo.normalize(path)
            return repos.contains(key) ? key : nil
        }
        let taskRepos = input.taskRepos.map(\.repoRelativePath)

        if let repo = known(input.pin) { return BaseSubject(repo: repo, reason: .pinned) }
        if let repo = known(input.selectedRepo) { return BaseSubject(repo: repo, reason: .selection) }
        if let directory = input.threadDirectory,
           let repo = known(repository(containing: directory, scopeRoot: input.scopeRoot, repos: repos, taskRepos: input.taskRepos)) {
            return BaseSubject(repo: repo, reason: .thread)
        }
        if let focus = input.deltaFocus.map(TaskRepo.normalize), taskRepos.contains(focus), let repo = known(focus) {
            return BaseSubject(repo: repo, reason: .delta)
        }
        if let repo = taskRepos.lazy.compactMap(known).first { return BaseSubject(repo: repo, reason: .task) }
        if let repo = known(input.recent) { return BaseSubject(repo: repo, reason: .recent) }
        return repos.first.map { BaseSubject(repo: $0, reason: .first) }
    }

    /// The repository `directory` is inside: a task sandbox maps to the repository it is a worktree of, a base
    /// checkout to itself. The deepest match wins, so a repository nested in another is not mistaken for its
    /// parent. A directory at the root of a multi-repo scope is inside none.
    static func repository(containing directory: String, scopeRoot: String, repos: [String], taskRepos: [TaskRepo]) -> String? {
        let directory = standardized(directory)
        var candidates = taskRepos.map { (root: standardized($0.sandboxPath), repo: $0.repoRelativePath) }
        let root = standardized(scopeRoot)
        candidates += repos.map { (root: $0 == "." ? root : standardized(root + "/" + $0), repo: $0) }
        return candidates
            .filter { directory == $0.root || directory.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }?
            .repo
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
