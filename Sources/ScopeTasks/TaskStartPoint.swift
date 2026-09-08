import Foundation
import ScopeGit

/// What a task's sandbox is checked out from (spec §4.3).
///
/// The default is a new branch off the repository's base. The other two cases continue work that already
/// exists — a branch, or the head of a pull request — in which case the task's branch *is* that branch and
/// nothing is created.
public enum TaskStartPoint: Sendable, Equatable, Hashable {
    /// A new branch from `origin/<default>` (the local default branch when there is no origin).
    case defaultBranch
    /// An existing branch: the local one when it exists, else `origin/<name>`.
    case existingBranch(String)
    /// The head of a pull request: `origin/<headRefName>`, or `pull/<n>/head` fetched into
    /// `refs/remotes/origin/pr/<n>` for a fork.
    case pullRequest(PullRequest)

    /// `true` for a start point that continues an existing branch rather than opening one.
    public var continuesExistingWork: Bool {
        if case .defaultBranch = self { return false }
        return true
    }

    /// The branch a task on this start point must use, if the start point dictates one.
    ///
    /// A same-repository pull request is worked on its own head branch; a fork's head has no branch on
    /// `origin`, so it is checked out as `pr/<n>`.
    public var requiredBranch: String? {
        switch self {
        case .defaultBranch: nil
        case .existingBranch(let name): name
        case .pullRequest(let pr): pr.isCrossRepository ? "pr/\(pr.number)" : pr.headRefName
        }
    }

    /// The pull request this start point follows, if any.
    public var pullRequest: PullRequest? {
        if case .pullRequest(let pr) = self { return pr }
        return nil
    }
}

extension String {
    /// `nil` when the string is empty — used where an absent value and an empty one mean the same thing.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
