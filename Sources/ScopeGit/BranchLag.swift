import Foundation
import ScopeCore

/// Where a task branch stands against `origin/<default>` after a fetch: how far behind, how far ahead, and
/// whether bringing the default branch in would conflict — without touching the working tree.
///
/// Conflicts come from `git merge-tree --write-tree` (git ≥ 2.38), which merges in memory and lists the paths it
/// could not resolve. An older git cannot say: `conflictsKnown` is then `false` and `conflicts` empty, so a caller
/// never mistakes "unknown" for "clean".
public struct BranchLag: Sendable, Equatable, Codable {
    /// The ref measured against: `origin/main`, or the local `main` when the repository has no remote.
    public var upstream: String
    /// Sha of `upstream` at the time of the measure: what "once per main head" is keyed on.
    public var upstreamHead: String
    /// Commits on the branch that `upstream` does not have.
    public var ahead: Int
    /// Commits on `upstream` that the branch does not have.
    public var behind: Int
    /// Paths a merge of `upstream` into the branch would leave in conflict.
    public var conflicts: [String]
    /// `false` when git could not run the dry merge (too old): `conflicts` says nothing then.
    public var conflictsKnown: Bool
    /// Subjects of the commits the branch is behind by, newest first: what names the merged pull requests.
    public var behindSubjects: [String]
    /// Behind without conflicts: the paths both the branch and `upstream` changed since they forked — where the next
    /// move of main may conflict. `nil` when not measured (up to date, conflicting, or an older reading).
    public var overlaps: [String]?
    public var checkedAt: Date

    public init(upstream: String, upstreamHead: String, ahead: Int = 0, behind: Int = 0, conflicts: [String] = [],
                conflictsKnown: Bool = true, behindSubjects: [String] = [], overlaps: [String]? = nil, checkedAt: Date = .now) {
        self.upstream = upstream
        self.upstreamHead = upstreamHead
        self.ahead = ahead
        self.behind = behind
        self.conflicts = conflicts
        self.conflictsKnown = conflictsKnown
        self.behindSubjects = behindSubjects
        self.overlaps = overlaps
        self.checkedAt = checkedAt
    }

    public var isBehind: Bool { behind > 0 }

    /// The paths named in both `git diff --name-only` outputs, sorted.
    public static func overlapping(_ theirs: String, _ ours: String) -> [String] {
        func paths(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return paths(theirs).intersection(paths(ours)).sorted()
    }
    public var hasConflicts: Bool { !conflicts.isEmpty }

    /// The pull requests merged into `upstream` that the branch does not have yet, from the subjects GitHub
    /// writes: `Title (#12)` for a squash or rebase merge, `Merge pull request #12 from …` for a merge commit.
    public var mergedPullRequests: [Int] { Self.pullRequestNumbers(in: behindSubjects) }

    public static func pullRequestNumbers(in subjects: [String]) -> [Int] {
        var numbers: [Int] = []
        for subject in subjects {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            var found: Int?
            if trimmed.hasPrefix("Merge pull request #") {
                let rest = trimmed.dropFirst("Merge pull request #".count)
                found = Int(rest.prefix { $0.isNumber })
            } else if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
                let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
                if inside.hasPrefix("#") { found = Int(inside.dropFirst()) }
            }
            if let found, !numbers.contains(found) { numbers.append(found) }
        }
        return numbers
    }

    /// The conflicted paths of a `git merge-tree --write-tree --name-only` output: the tree id on the first line,
    /// then one path per line, then a blank line and the informational messages.
    static func conflictedPaths(in output: String) -> [String] {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }
        lines.removeFirst()   // the tree id
        var paths: [String] = []
        for line in lines {
            if line.isEmpty { break }
            paths.append(line)
        }
        return paths
    }
}

/// The result of `GitClient.rebase(at:onto:)`.
public enum RebaseOutcome: Sendable, Equatable {
    /// `HEAD` moved onto the upstream; `from` is the sha it stood on before, what a push with lease expects on the remote.
    case rebased(from: String, to: String)
    /// Nothing to do: the branch already contains the upstream.
    case upToDate
    /// The rebase stopped on these paths; it was aborted and the branch is exactly where it was.
    case conflicted(paths: [String])
    /// The checkout has uncommitted changes: a rebase would refuse, or sweep them along. Nothing was run.
    case dirty
}

public extension GitClient {
    /// Where the branch checked out at `checkout` stands against `origin/<default>`, after `git fetch` when asked.
    /// `checkout` may be a worktree of this client's repository: every command runs with `-C`.
    func branchLag(at checkout: URL, defaultBranch: String? = nil, fetch: Bool = true) async throws -> BranchLag {
        let c = ["-C", checkout.filesystemPath]
        if fetch, await hasRemote() {
            try await run(c + ["fetch", "--prune", "--quiet", "origin"], timeout: .seconds(120))
        }
        let upstream = try await Delta.upstreamRef(c: c, using: self, defaultBranch: defaultBranch)
        let head = try await output(c + ["rev-parse", "\(upstream)^{commit}"], timeout: .seconds(10))
        let counts = try await Delta.aheadBehind(c: c, upstream: upstream, using: self)
        var lag = BranchLag(upstream: upstream, upstreamHead: head, ahead: counts.0, behind: counts.1)
        guard lag.behind > 0 else { return lag }
        lag.behindSubjects = try await Delta.log(c: c, range: "HEAD..\(upstream)", using: self).map(\.subject)
        // Exit 0: merges cleanly. Exit 1: conflicts, listed. Anything else: git could not do the dry merge.
        let merge = try await run(c + ["merge-tree", "--write-tree", "--name-only", "HEAD", upstream],
                                  timeout: .seconds(60), allowFailure: true)
        switch merge.exitCode {
        case 0:
            let theirs = try? await output(c + ["diff", "--name-only", "HEAD...\(upstream)"], timeout: .seconds(30))
            let ours = try? await output(c + ["diff", "--name-only", "\(upstream)...HEAD"], timeout: .seconds(30))
            if let theirs, let ours { lag.overlaps = BranchLag.overlapping(theirs, ours) }
        case 1: lag.conflicts = BranchLag.conflictedPaths(in: merge.stdoutText)
        default: lag.conflictsKnown = false
        }
        return lag
    }

    /// `git rebase <upstream>` in the checkout at `checkout`. A rebase that stops is aborted, and the branch is
    /// checked to be back on the commit it started from; a clean tree is required, so nothing of the user's can be
    /// swept along or lost. Never runs in the client's own repository: a task's sandbox only.
    func rebase(at checkout: URL, onto upstream: String) async throws -> RebaseOutcome {
        let c = ["-C", checkout.filesystemPath]
        if try await hasUncommittedChanges(at: checkout) { return .dirty }
        let before = try await output(c + ["rev-parse", "HEAD"], timeout: .seconds(10))
        let base = try await run(c + ["merge-base", "--is-ancestor", upstream, "HEAD"], timeout: .seconds(30), allowFailure: true)
        if base.succeeded { return .upToDate }
        let result = try await run(c + ["rebase", upstream], environment: ["GIT_EDITOR": "true"],
                                   timeout: .seconds(300), allowFailure: true)
        if result.succeeded {
            let after = try await output(c + ["rev-parse", "HEAD"], timeout: .seconds(10))
            return .rebased(from: before, to: after)
        }
        let paths = try await conflictedPaths(c: c)
        try await run(c + ["rebase", "--abort"], timeout: .seconds(60), allowFailure: true)
        // `--abort` restores the branch itself; the reset is the belt to its braces, safe on the clean tree checked above.
        let restored = try await output(c + ["rev-parse", "HEAD"], timeout: .seconds(10))
        if restored != before {
            try await run(c + ["reset", "--hard", "--quiet", before], timeout: .seconds(60))
        }
        return .conflicted(paths: paths)
    }

    /// `true` when `origin/<branch>` exists: the branch was pushed at least once.
    func isPublished(_ branch: String, at checkout: URL) async -> Bool {
        let c = ["-C", checkout.filesystemPath]
        return (try? await run(c + ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}"],
                               timeout: .seconds(10), allowFailure: true).succeeded) ?? false
    }

    /// `git push --force-with-lease --force-if-includes origin <branch>`: the remote must still be where the last
    /// fetch saw it, and every commit it had must be in what is pushed. Someone else's push in between is refused.
    func pushWithLease(_ branch: String, at checkout: URL, timeout: Duration? = .seconds(180)) async throws {
        let c = ["-C", checkout.filesystemPath]
        try await run(c + ["push", "--quiet", "--force-with-lease", "--force-if-includes", "origin", branch], timeout: timeout)
    }

    /// Paths in conflict in the checkout (`git diff --name-only --diff-filter=U`).
    private func conflictedPaths(c: [String]) async throws -> [String] {
        let result = try await run(c + ["diff", "--name-only", "--diff-filter=U", "-z"], timeout: .seconds(30), allowFailure: true)
        return result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }
}
