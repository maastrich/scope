import Foundation
import ScopeCore

/// Why a try in the user's checkout was refused or could not be finished (spec §4.5, "Try in my checkout").
public enum TryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A rebase, merge, cherry-pick, revert or bisect is under way in the checkout: nothing moves until it is over.
    case operationInProgress(String)
    /// Paths left in conflict: `git stash` refuses them, so the changes could not be set aside.
    case unmergedPaths([String])
    /// The task branch does not exist in this repository.
    case branchMissing(String)
    /// `git stash push` ran but left no new entry: the changes are still there, nothing was switched.
    case stashNotRecorded
    /// The checkout is back on its branch, but the stash would not apply cleanly: it is kept under this sha and the
    /// tree holds the conflicts for the user to resolve.
    case stashConflicts(sha: String)
    /// The detached checkout could not be moved to the task branch's head: uncommitted changes in the base overlap it.
    case refreshBlocked(String)

    public var description: String {
        switch self {
        case .operationInProgress(let kind): "a \(kind) is in progress in the checkout"
        case .unmergedPaths(let paths): "\(paths.count) \(paths.count == 1 ? "path is" : "paths are") in conflict and cannot be stashed"
        case .branchMissing(let branch): "branch \(branch) does not exist in this repository"
        case .stashNotRecorded: "git stash saved nothing; the checkout was left as it was"
        case .stashConflicts(let sha): "the stashed changes did not apply cleanly; they are kept in stash \(String(sha.prefix(10)))"
        case .refreshBlocked(let why): "the checkout could not be moved: \(why)"
        }
    }
}

/// Where the user's checkout stood before a try, so that it can be put back exactly.
public struct TryCheckout: Sendable, Equatable, Codable {
    /// Sha `HEAD` was at.
    public var previousHead: String
    /// The branch that was checked out; `nil` when `HEAD` was already detached.
    public var previousBranch: String?
    /// The stash holding what was not committed, `nil` when the tree was clean.
    public var stashSHA: String?
    /// The commit of the task branch the checkout was detached onto.
    public var head: String

    public init(previousHead: String, previousBranch: String?, stashSHA: String?, head: String) {
        self.previousHead = previousHead
        self.previousBranch = previousBranch
        self.stashSHA = stashSHA
        self.head = head
    }
}

/// The outcome of `GitClient.endTry`.
public enum PutBackOutcome: Sendable, Equatable {
    /// Branch back, stash applied and dropped (or there was none).
    case restored
    /// Branch back, but the stash conflicted: kept under `stashSHA`, the tree shows the conflicts.
    case stashKept(sha: String)
}

/// Running a task's branch in the user's own checkout, then putting everything back (spec §4.5). This is the one
/// place Scope moves a base checkout, so every step is the reversible one: changes are stashed, never discarded;
/// `HEAD` is detached onto the task branch, so the user's branch itself never moves; coming back is `git switch`
/// to the branch and `git stash apply`, never `reset --hard`. The checkout's own hooks run as they would for the
/// user: Scope's sandbox hooks are not involved.
public extension GitClient {
    /// The label of the stash a try makes, so a user reading `git stash list` knows whose it is.
    static func tryStashLabel(task: String, at date: Date = .now) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "")
        return "scope-try-\(task)-\(stamp)"
    }

    /// The label of the stash a put back makes of changes made in the checkout while trying.
    static func tryEditsStashLabel(task: String, at date: Date = .now) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "")
        return "scope-try-edits-\(task)-\(stamp)"
    }

    /// The operation under way in the checkout, as git keeps it (`rebase`, `merge`, `cherry-pick`, `revert`,
    /// `bisect`), or `nil` when none is.
    func operationInProgress() async -> String? {
        let markers: [(path: String, kind: String)] = [
            ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"),
        ]
        for marker in markers {
            guard let path = try? await output(["rev-parse", "--git-path", marker.path], timeout: .seconds(10)) else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) { return marker.kind }
        }
        return nil
    }

    /// Takes the checkout onto `branch`, detached. Refuses an operation in progress and conflicted paths; stashes
    /// anything uncommitted (untracked included) under `label` and remembers where `HEAD` was. If the switch itself
    /// fails the stash is applied back and dropped, so the checkout is left as found.
    func beginTry(branch: String, label: String) async throws -> TryCheckout {
        if let kind = await operationInProgress() { throw TryError.operationInProgress(kind) }
        guard await branchExists(branch) else { throw TryError.branchMissing(branch) }
        let status = GitStatus(porcelainV2: try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
                                                           timeout: .seconds(30)).stdout)
        if status.hasConflicts { throw TryError.unmergedPaths(status.entries.filter(\.isUnmerged).map(\.path)) }
        let previousHead = try await output(["rev-parse", "HEAD"], timeout: .seconds(10))
        let previousBranch = status.branchName

        var stashSHA: String?
        if status.isDirty {
            let before = try? await output(["rev-parse", "--quiet", "--verify", "refs/stash"], timeout: .seconds(10))
            try await run(["stash", "push", "--quiet", "--include-untracked", "-m", label], timeout: .seconds(120))
            let after = try? await output(["rev-parse", "--quiet", "--verify", "refs/stash"], timeout: .seconds(10))
            guard let after, !after.isEmpty, after != before else { throw TryError.stashNotRecorded }
            stashSHA = after
        }
        do {
            try await run(["switch", "--quiet", "--detach", branch], timeout: .seconds(120))
        } catch {
            if let stashSHA {
                _ = try? await run(["stash", "apply", "--quiet", stashSHA], timeout: .seconds(120), allowFailure: true)
                try? await dropStash(stashSHA)
            }
            throw error
        }
        let head = try await output(["rev-parse", "HEAD"], timeout: .seconds(10))
        return TryCheckout(previousHead: previousHead, previousBranch: previousBranch, stashSHA: stashSHA, head: head)
    }

    /// Puts the checkout back where `beginTry` found it: on its branch (or detached at its commit when it was),
    /// with its stash applied and dropped. Changes made in the checkout while trying are stashed under
    /// `editsLabel` and kept — put back never discards anything. A stash that conflicts is kept too, and the
    /// outcome says so; the branch is back either way.
    func endTry(_ checkout: TryCheckout, editsLabel: String) async throws -> PutBackOutcome {
        if let kind = await operationInProgress() { throw TryError.operationInProgress(kind) }
        if try await hasUncommittedChanges(at: repository) {
            try await run(["stash", "push", "--quiet", "--include-untracked", "-m", editsLabel], timeout: .seconds(120))
        }
        if let branch = checkout.previousBranch, await branchExists(branch) {
            try await run(["switch", "--quiet", branch], timeout: .seconds(120))
        } else {
            try await run(["switch", "--quiet", "--detach", checkout.previousHead], timeout: .seconds(120))
        }
        guard let sha = checkout.stashSHA else { return .restored }
        guard await stashExists(sha) else { return .restored }   // already applied by hand
        let applied = try await run(["stash", "apply", "--quiet", sha], timeout: .seconds(120), allowFailure: true)
        guard applied.succeeded else { return .stashKept(sha: sha) }
        try await dropStash(sha)
        return .restored
    }

    /// Moves the detached checkout to the current head of `branch` (the sandbox moved on). A clean tree is switched;
    /// a dirty one is fast-forwarded with `git merge --ff-only`, which refuses when the changes overlap or the
    /// branch was rewritten. Returns the new head.
    func refreshTry(branch: String) async throws -> String {
        if let kind = await operationInProgress() { throw TryError.operationInProgress(kind) }
        guard await branchExists(branch) else { throw TryError.branchMissing(branch) }
        if try await hasUncommittedChanges(at: repository) {
            let result = try await run(["merge", "--ff-only", "--quiet", branch], timeout: .seconds(120), allowFailure: true)
            guard result.succeeded else {
                throw TryError.refreshBlocked(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            try await run(["switch", "--quiet", "--detach", branch], timeout: .seconds(120))
        }
        return try await output(["rev-parse", "HEAD"], timeout: .seconds(10))
    }

    /// `true` when a stash entry with this sha is still listed.
    func stashExists(_ sha: String) async -> Bool {
        await stashIndex(of: sha) != nil
    }

    /// `stash@{n}` of the entry whose commit is `sha`: entries move when others are pushed or dropped, so the sha is
    /// what is remembered and the index looked up at the last moment.
    private func stashIndex(of sha: String) async -> Int? {
        guard let text = try? await output(["stash", "list", "--format=%H"], timeout: .seconds(30)) else { return nil }
        return text.split(separator: "\n").firstIndex { $0 == sha }
    }

    private func dropStash(_ sha: String) async throws {
        guard let index = await stashIndex(of: sha) else { return }
        try await run(["stash", "drop", "--quiet", "stash@{\(index)}"], timeout: .seconds(30))
    }
}
