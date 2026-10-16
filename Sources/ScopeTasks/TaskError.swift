import Foundation
import ScopeGit

/// Failures of `TaskManager`. Git failures are wrapped with the repo they concern.
public enum TaskError: Error, Sendable, CustomStringConvertible {
    /// The base checkout `<scopeRoot>/<repo>` does not exist or is not a git repository.
    case repoNotFound(repo: String)
    /// The repo is already part of the task.
    case repoAlreadyInTask(repo: String)
    /// The repo could not name a default branch (no `origin/HEAD`, no `init.defaultBranch`, no `main` / `master`).
    case noDefaultBranch(repo: String)
    /// A repo scope task can only hold the scope itself (`"."`), and cannot mix it with sub-repos.
    case invalidRepoSelection(String)
    /// The task is archived; only `close` and `reopen`-style operations apply.
    case taskArchived
    /// A git command failed for `repo`.
    case git(repo: String, GitError)
    /// A worktree guardrail fired for `repo`.
    case worktree(repo: String, WorktreeError)
    /// The record could not be written.
    case persistence(String)
    /// `createForPullRequest`: the head of the pull request could not be fetched from `origin`.
    case pullRequestHeadMissing(repo: String, ref: String)
    /// `create`: the branch name is empty or uses the reserved `scope/` prefix (`TaskBranch.reservedPrefix`).
    case invalidBranch(String)
    /// `TaskStartPoint.existingBranch`: no such branch locally or on `origin`.
    case branchNotFound(repo: String, branch: String)
    /// The branch is checked out in another working tree; git refuses a second worktree on it.
    case branchAlreadyCheckedOut(repo: String, branch: String, path: String)
    /// `TaskCheckpoints`: the task has no checkpoint with that number (pruned, or never taken).
    case checkpointNotFound(Int)

    public var description: String {
        switch self {
        case .repoNotFound(let repo): "\(repo) is not a git repository of this scope"
        case .repoAlreadyInTask(let repo): "\(repo) is already part of this task"
        case .noDefaultBranch(let repo): "\(repo): cannot determine the default branch"
        case .invalidRepoSelection(let reason): reason
        case .taskArchived: "the task is archived"
        case .git(let repo, let error): "\(repo): \(error.description)"
        case .worktree(let repo, let error): "\(repo): \(error.description)"
        case .persistence(let message): message
        case .pullRequestHeadMissing(let repo, let ref): "\(repo): \(ref) is not on origin after fetch"
        case .invalidBranch(let branch): branch.isEmpty ? "the task needs a branch name" : TaskBranch.reservedRefusal(branch)
        case .branchNotFound(let repo, let branch): "\(repo): no branch \(branch), locally or on origin"
        case .branchAlreadyCheckedOut(let repo, let branch, let path):
            "\(repo): \(branch) is already checked out at \(path) — a branch can only live in one working tree"
        case .checkpointNotFound(let number): "the task has no checkpoint \(number)"
        }
    }
}
