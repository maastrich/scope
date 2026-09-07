import Foundation
import ScopeGit

/// Failures of `TaskManager`. Git failures are wrapped with the repo they concern.
public enum TaskError: Error, Sendable, CustomStringConvertible {
    /// Guardrail (spec §6): the sandbox of `repo` has uncommitted changes; pass `force` after the user confirmed.
    case uncommittedChanges(repo: String)
    /// `close(deleteBranch: true)` on a branch not merged into HEAD; pass `force` (→ `branch -D`) after confirmation.
    case branchNotMerged(repo: String, branch: String)
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

    public var description: String {
        switch self {
        case .uncommittedChanges(let repo): "\(repo) has uncommitted changes"
        case .branchNotMerged(let repo, let branch): "\(repo): branch \(branch) is not merged"
        case .repoNotFound(let repo): "\(repo) is not a git repository of this scope"
        case .repoAlreadyInTask(let repo): "\(repo) is already part of this task"
        case .noDefaultBranch(let repo): "\(repo): cannot determine the default branch"
        case .invalidRepoSelection(let reason): reason
        case .taskArchived: "the task is archived"
        case .git(let repo, let error): "\(repo): \(error.description)"
        case .worktree(let repo, let error): "\(repo): \(error.description)"
        case .persistence(let message): message
        case .pullRequestHeadMissing(let repo, let ref): "\(repo): \(ref) is not on origin after fetch"
        }
    }
}
