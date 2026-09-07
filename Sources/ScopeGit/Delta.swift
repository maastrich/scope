import Foundation
import ScopeCore

/// The three Delta views of spec §4.4, computed on one checkout (a sandbox, or the base for `.baseVsOrigin`).
public enum DeltaMode: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// Task branch vs its merge-base with the default branch, *including* the working tree.
    ///
    /// Decision: the diff is `git diff <merge-base>` (merge-base → working tree), not
    /// `<merge-base>..HEAD`, so an agent's uncommitted edits show up in the task delta right away
    /// instead of appearing only after a commit. Untracked files are included (see `Delta.load`).
    case task
    /// Working tree vs `HEAD` (`git diff HEAD` + untracked files).
    case uncommitted
    /// Is this checkout behind / ahead of `origin/<default>`? Counts and commit lists, no file diff.
    case baseVsOrigin
}

/// One commit of a `baseVsOrigin` list.
public struct DeltaCommit: Sendable, Equatable, Hashable, Identifiable {
    public let sha: String
    public let subject: String
    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
}

/// Result of `Delta.load`.
public struct Delta: Sendable, Equatable {
    public let mode: DeltaMode
    /// Files, sorted by path. Empty for `.baseVsOrigin`.
    public let files: [DiffFile]
    public let summary: DiffSummary
    /// The ref the diff was computed against: the merge-base sha (`.task`), `"HEAD"` (`.uncommitted`),
    /// `origin/<default>` (`.baseVsOrigin`).
    public let base: String?
    /// Commits on `HEAD` not on `origin/<default>` (`.baseVsOrigin` only; also filled for `.task`).
    public let ahead: Int
    /// Commits on `origin/<default>` not on `HEAD` (`.baseVsOrigin` only; also filled for `.task`).
    public let behind: Int
    /// `git log origin/<default>..HEAD` (`.baseVsOrigin` only).
    public let commitsAhead: [DeltaCommit]
    /// `git log HEAD..origin/<default>` (`.baseVsOrigin` only).
    public let commitsBehind: [DeltaCommit]

    public init(
        mode: DeltaMode, files: [DiffFile] = [], base: String? = nil,
        ahead: Int = 0, behind: Int = 0, commitsAhead: [DeltaCommit] = [], commitsBehind: [DeltaCommit] = []
    ) {
        self.mode = mode
        self.files = files
        self.summary = DiffSummary(files)
        self.base = base
        self.ahead = ahead
        self.behind = behind
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
    }

    /// Arguments shared by every patch-producing command.
    public static let diffArguments = ["-c", "core.quotePath=false", "diff", "--no-color", "-M", "--no-ext-diff"]
    /// Untracked files bigger than this are listed as `.added` without hunks.
    public static let maxInlineUntrackedBytes = 512 * 1024
    /// Cap on `git diff --no-index` calls per load (one process per untracked file).
    public static let maxInlineUntrackedFiles = 200
    public static let commandTimeout: Duration = .seconds(60)

    /// Loads the delta of the checkout at `checkout` through `client`.
    ///
    /// - Parameters:
    ///   - mode: which view.
    ///   - checkout: the working tree to inspect (a sandbox or a base). `client` may belong to the
    ///     base repository: every command is run with `-C <checkout>`.
    ///   - client: serial client of the repository.
    ///   - defaultBranch: `main`… when already known; otherwise resolved through `RepoFacts`.
    /// - Throws: `GitError` when a required command fails (`.task` on an unborn branch, unrelated histories…).
    public static func load(
        mode: DeltaMode, in checkout: URL, using client: GitClient, defaultBranch: String? = nil
    ) async throws -> Delta {
        let dir = checkout.filesystemPath
        let c = ["-C", dir]

        switch mode {
        case .uncommitted:
            let tracked = try await patch(c + diffArguments + ["HEAD"], numstat: c + diffArguments + ["--numstat", "-z", "HEAD"], using: client)
            let untracked = try await untrackedFiles(c: c, checkout: checkout, using: client)
            return Delta(mode: .uncommitted, files: sorted(tracked + untracked), base: "HEAD")

        case .task:
            let upstream = try await upstreamRef(c: c, using: client, defaultBranch: defaultBranch)
            guard let mergeBase = try await mergeBase(c: c, upstream: upstream, using: client) else {
                throw GitError(arguments: ["merge-base", upstream, "HEAD"], result: ProcessResult(
                    exitCode: 1, terminationReason: .exit, stdout: Data(),
                    stderr: Data("no merge-base between \(upstream) and HEAD".utf8)))
            }
            let tracked = try await patch(c + diffArguments + [mergeBase], numstat: c + diffArguments + ["--numstat", "-z", mergeBase], using: client)
            let untracked = try await untrackedFiles(c: c, checkout: checkout, using: client)
            let counts = (try? await aheadBehind(c: c, upstream: upstream, using: client)) ?? (0, 0)
            return Delta(mode: .task, files: sorted(tracked + untracked), base: mergeBase, ahead: counts.0, behind: counts.1)

        case .baseVsOrigin:
            let upstream = try await upstreamRef(c: c, using: client, defaultBranch: defaultBranch)
            let counts = try await aheadBehind(c: c, upstream: upstream, using: client)
            let ahead = try await log(c: c, range: "\(upstream)..HEAD", using: client)
            let behind = try await log(c: c, range: "HEAD..\(upstream)", using: client)
            return Delta(mode: .baseVsOrigin, base: upstream, ahead: counts.0, behind: counts.1, commitsAhead: ahead, commitsBehind: behind)
        }
    }

    // MARK: - Steps

    /// `origin/<default>` when that ref exists, else the local `<default>` branch (no remote).
    static func upstreamRef(c: [String], using client: GitClient, defaultBranch: String?) async throws -> String {
        let branch: String
        if let defaultBranch { branch = defaultBranch }
        else if let resolved = await client.defaultBranch() { branch = resolved }
        else {
            throw GitError(arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"], result: ProcessResult(
                exitCode: 1, terminationReason: .exit, stdout: Data(), stderr: Data("cannot determine the default branch".utf8)))
        }
        let remote = "origin/\(branch)"
        let exists = try await client.run(c + ["rev-parse", "--verify", "--quiet", "\(remote)^{commit}"], timeout: commandTimeout, allowFailure: true)
        return exists.succeeded ? remote : branch
    }

    static func mergeBase(c: [String], upstream: String, using client: GitClient) async throws -> String? {
        let result = try await client.run(c + ["merge-base", upstream, "HEAD"], timeout: commandTimeout, allowFailure: true)
        guard result.succeeded else { return nil }
        let sha = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    static func aheadBehind(c: [String], upstream: String, using client: GitClient) async throws -> (Int, Int) {
        let text = try await client.output(c + ["rev-list", "--left-right", "--count", "HEAD...\(upstream)"], timeout: commandTimeout)
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    static func log(c: [String], range: String, using client: GitClient) async throws -> [DeltaCommit] {
        let result = try await client.run(c + ["log", "--no-color", "--format=%H%x00%s", "-z", range], timeout: commandTimeout)
        // With -z each record ends in NUL; our format also puts a NUL between sha and subject.
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var commits: [DeltaCommit] = []
        var index = 0
        while index + 1 < fields.count {
            let sha = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = fields[index + 1]
            if sha.count == 40 { commits.append(DeltaCommit(sha: sha, subject: subject)) }
            index += 2
        }
        return commits
    }

    /// Runs the patch command and the numstat command, merges the counts.
    static func patch(_ arguments: [String], numstat: [String], using client: GitClient) async throws -> [DiffFile] {
        let patchResult = try await client.run(arguments, timeout: commandTimeout)
        var files = DiffParser.parse(patchResult.stdoutText)
        if let stats = try? await client.run(numstat, timeout: commandTimeout) {
            files = DiffParser.merge(files, numstat: DiffParser.parseNumstat(stats.stdout))
        }
        return files
    }

    /// Untracked files (from `status --untracked-files=all`) as `.added` files, inlined with
    /// `git diff --no-index /dev/null <file>` when small and text.
    static func untrackedFiles(c: [String], checkout: URL, using client: GitClient) async throws -> [DiffFile] {
        let status = try await client.run(c + ["status", "--porcelain=v2", "-z", "--untracked-files=all"], timeout: commandTimeout)
        let paths = GitStatus(porcelainV2: status.stdout).entries.filter(\.isUntracked).map(\.path)
        var files: [DiffFile] = []
        var inlined = 0
        for path in paths {
            let url = checkout.appending(path: path, directoryHint: .notDirectory)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let data = size <= maxInlineUntrackedBytes ? try? Data(contentsOf: url) : nil
            let isText = data.map { !$0.prefix(8000).contains(0) } ?? false
            if size == 0 {
                files.append(DiffFile(path: path, status: .added))
                continue
            }
            guard isText, inlined < maxInlineUntrackedFiles else {
                files.append(DiffFile(path: path, status: isText ? .added : .binary))
                continue
            }
            inlined += 1
            // --no-index exits 1 when the files differ, which is the expected outcome.
            let result = try await client.run(
                c + diffArguments + ["--no-index", "--", "/dev/null", url.filesystemPath],
                timeout: commandTimeout, allowFailure: true
            )
            if let parsed = DiffParser.parse(result.stdoutText).first {
                files.append(DiffFile(path: path, status: .added, additions: parsed.additions, deletions: 0, hunks: parsed.hunks))
            } else {
                files.append(DiffFile(path: path, status: .added))
            }
        }
        return files
    }

    static func sorted(_ files: [DiffFile]) -> [DiffFile] {
        files.sorted { $0.path < $1.path }
    }
}
