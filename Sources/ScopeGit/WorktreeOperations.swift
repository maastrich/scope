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

    /// The checkout that currently has `branch` checked out — the main working tree or one of its
    /// worktrees — or `nil` when no checkout holds it.
    ///
    /// git refuses `worktree add` for a branch that is already checked out somewhere; asking first turns
    /// that into an error the UI can explain.
    func worktreePath(ofBranch branch: String) async -> String? {
        guard let data = try? await run(["worktree", "list", "--porcelain"], timeout: .seconds(30)).stdout else { return nil }
        let output = String(decoding: data, as: UTF8.self)
        var path: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return path
            }
        }
        return nil
    }

    /// Adds a worktree at `path` on `branch`.
    ///
    /// - When the branch does not exist: `git worktree add <path> -b <branch> <startPoint>`.
    /// - When it already exists (task reopened, sandbox recreated): `git worktree add <path> <branch>`.
    ///
    /// Leading directories of `path` are created by git. The folder must not exist or be empty.
    ///
    /// A failed add is undone, so the next attempt starts from the same place: git creates the branch before it
    /// checks out, and a checkout that dies half-way (a missing `git-lfs`, a full disk) left the branch behind and
    /// sent every retry down the existing-branch path. The folder goes when this call created it, git's record of
    /// it is pruned, and a branch this call created goes too while it still points at the start point — it holds
    /// no commit of its own. The original error is rethrown.
    func createWorktree(at path: URL, branch: String, from startPoint: String?) async throws {
        let target = path.filesystemPath
        let folderBefore = FolderState(at: target)
        if await branchExists(branch) {
            do {
                try await run(["worktree", "add", target, branch], timeout: .seconds(120))
            } catch {
                await undoFailedAdd(at: path, folderBefore: folderBefore, createdBranch: nil)
                throw error
            }
        } else {
            guard let startPoint else { throw WorktreeError.missingStartPoint(branch: branch) }
            let startCommit = try? await output(["rev-parse", "--verify", "--quiet", "\(startPoint)^{commit}"], timeout: .seconds(10))
            do {
                try await run(["worktree", "add", target, "-b", branch, startPoint], timeout: .seconds(120))
            } catch {
                await undoFailedAdd(at: path, folderBefore: folderBefore, createdBranch: startCommit.map { (branch, $0) })
                throw error
            }
        }
    }

    /// The cleanup of `createWorktree`. Best effort: each step runs whatever the previous one did. The folder goes
    /// before the prune and the prune before the branch — git refuses to delete a branch a worktree still holds.
    /// A folder that held anything before the attempt is never touched: git refused it, nothing in it is ours.
    private func undoFailedAdd(at path: URL, folderBefore: FolderState, createdBranch: (name: String, startCommit: String)?) async {
        let target = path.filesystemPath
        switch folderBefore {
        case .absent:
            try? FileManager.default.removeItem(at: path)
        case .empty:
            // git's own cleanup may have removed it: put back the empty folder the caller had.
            for item in (try? FileManager.default.contentsOfDirectory(atPath: target)) ?? [] {
                try? FileManager.default.removeItem(atPath: (target as NSString).appendingPathComponent(item))
            }
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        case .occupied:
            break
        }
        try? await prune()
        guard let createdBranch else { return }
        let tip = try? await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(createdBranch.name)"], timeout: .seconds(10))
        guard tip == createdBranch.startCommit else { return }
        try? await deleteBranch(name: createdBranch.name, force: true)
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

/// What was at a worktree's path before `createWorktree` ran, so a failed add removes only what it made.
private enum FolderState {
    case absent, empty, occupied

    init(at path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            self = .absent
        } else if let items = try? FileManager.default.contentsOfDirectory(atPath: path), items.isEmpty {
            self = .empty
        } else {
            self = .occupied
        }
    }
}
