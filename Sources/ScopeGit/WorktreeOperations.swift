import Foundation
import ScopeCore

/// A worktree / branch operation refused by Scope's guardrails (spec §6), before git ran.
public enum WorktreeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `removeWorktree(at:force:)` on a checkout with staged, unstaged or untracked changes.
    case uncommittedChanges(path: String)
    /// `createWorktree` without a start point when the branch does not exist yet.
    case missingStartPoint(branch: String)

    public var description: String {
        switch self {
        case .uncommittedChanges(let path): "worktree \(path) has uncommitted changes"
        case .missingStartPoint(let branch): "branch \(branch) does not exist and no start point was given"
        }
    }
}

/// Fetch, branch and worktree operations (M2). Every call runs on the repository's serial queue.
///
/// Worktree checkouts are addressed with `git -C <path>` from the *base* repository's client, so
/// the base and all its sandboxes share one queue: git's own locks are never raced from Scope.
public extension GitClient {
    /// `git fetch --prune <remote>`. Network: the default timeout is generous.
    func fetch(remote: String = "origin", timeout: Duration? = .seconds(120)) async throws {
        try await run(["fetch", "--prune", "--quiet", remote], timeout: timeout)
    }

    /// `git fetch <remote> <refspec>…`, e.g. `+pull/12/head:refs/remotes/origin/pr/12` for a fork's PR head.
    func fetch(remote: String = "origin", refspecs: [String], timeout: Duration? = .seconds(120)) async throws {
        try await run(["fetch", "--quiet", remote] + refspecs, timeout: timeout)
    }

    /// `true` when `git remote get-url <remote>` succeeds.
    func hasRemote(_ remote: String = "origin") async -> Bool {
        (try? await run(["remote", "get-url", remote], timeout: .seconds(10), allowFailure: true).succeeded) ?? false
    }

    /// Default branch name (see `RepoFacts`): `origin/HEAD`, then `init.defaultBranch`, then a local `main` / `master`.
    func defaultBranch() async -> String? {
        await RepoFacts.load(for: repository, using: self).defaultBranch
    }

    /// `true` when `refs/heads/<name>` exists.
    func branchExists(_ name: String) async -> Bool {
        (try? await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], timeout: .seconds(10), allowFailure: true).succeeded) ?? false
    }

    /// `true` when `<ref>` resolves (`origin/main`, a sha, `HEAD`…).
    func refExists(_ ref: String) async -> Bool {
        (try? await run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], timeout: .seconds(10), allowFailure: true).succeeded) ?? false
    }

    /// Adds a worktree at `path` on `branch`.
    ///
    /// - When the branch does not exist: `git worktree add <path> -b <branch> <startPoint>`.
    /// - When it already exists (task reopened, sandbox recreated): `git worktree add <path> <branch>`.
    ///
    /// Leading directories of `path` are created by git. The folder must not exist or be empty.
    func createWorktree(at path: URL, branch: String, from startPoint: String?) async throws {
        let target = path.filesystemPath
        if await branchExists(branch) {
            try await run(["worktree", "add", target, branch], timeout: .seconds(120))
        } else {
            guard let startPoint else { throw WorktreeError.missingStartPoint(branch: branch) }
            try await run(["worktree", "add", target, "-b", branch, startPoint], timeout: .seconds(120))
        }
    }

    /// Staged, unstaged, unmerged or untracked changes in the checkout at `path` (ignored files do not count).
    func hasUncommittedChanges(at path: URL) async throws -> Bool {
        let result = try await run(
            ["-C", path.filesystemPath, "status", "--porcelain=v2", "-z", "--untracked-files=normal"],
            timeout: .seconds(30)
        )
        return GitStatus(porcelainV2: result.stdout).isDirty
    }

    /// `git worktree remove [--force] <path>`.
    ///
    /// Guardrail: throws `WorktreeError.uncommittedChanges` when the checkout is dirty and `force`
    /// is false — the caller must have asked the user first. A path that is already gone from disk
    /// is removed from git's records (`prune`) instead of failing.
    func removeWorktree(at path: URL, force: Bool = false) async throws {
        let target = path.filesystemPath
        guard FileManager.default.fileExists(atPath: target) else {
            try await prune()
            return
        }
        if !force, try await hasUncommittedChanges(at: path) {
            throw WorktreeError.uncommittedChanges(path: target)
        }
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(target)
        try await run(arguments, timeout: .seconds(120))
    }

    /// `git worktree prune`: drops records whose checkout folder disappeared.
    func prune() async throws {
        try await run(["worktree", "prune"], timeout: .seconds(30))
    }

    /// `git branch -d <name>`, or `-D` with `force` (destructive: confirm with the user first, spec §6).
    func deleteBranch(name: String, force: Bool = false) async throws {
        try await run(["branch", force ? "-D" : "-d", name], timeout: .seconds(30))
    }

    /// `git merge-base <a> <b>`, `nil` when the histories are unrelated.
    func mergeBase(_ a: String, _ b: String) async throws -> String? {
        let result = try await run(["merge-base", a, b], timeout: .seconds(30), allowFailure: true)
        guard result.succeeded else { return nil }
        let sha = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// `(ahead, behind)` of `local` relative to `upstream` (`git rev-list --left-right --count local...upstream`).
    func aheadBehind(_ local: String, _ upstream: String) async throws -> (ahead: Int, behind: Int) {
        let text = try await output(["rev-list", "--left-right", "--count", "\(local)...\(upstream)"], timeout: .seconds(30))
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }
}
