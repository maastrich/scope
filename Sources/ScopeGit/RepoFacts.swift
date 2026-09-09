import Foundation
import ScopeCore

/// Git-backed facts about one repository: origin, default branch, current branch, status,
/// optionally worktrees. Loaded off the main actor through a `GitClient`; every piece is
/// independent, so a failing command leaves its field `nil` instead of failing the whole load.
public struct RepoFacts: Sendable, Equatable {
    /// `git remote get-url origin`, or the `.git/config` value when git could not run.
    public var originURL: String?
    /// `owner/repo` parsed from `originURL`.
    public var remote: RemoteInfo?
    /// `main`, `master`, `develop`… from `origin/HEAD`, else `init.defaultBranch`, else an existing local `main` / `master`.
    public var defaultBranch: String?
    /// Checked-out branch; `nil` when detached or on an unborn branch.
    public var currentBranch: String?
    public var status: GitStatus?
    /// Filled only when `load(includeWorktrees: true)`.
    public var worktrees: [GitWorktree]
    public var loadedAt: Date

    public init(
        originURL: String? = nil,
        remote: RemoteInfo? = nil,
        defaultBranch: String? = nil,
        currentBranch: String? = nil,
        status: GitStatus? = nil,
        worktrees: [GitWorktree] = [],
        loadedAt: Date = .now
    ) {
        self.originURL = originURL
        self.remote = remote
        self.defaultBranch = defaultBranch
        self.currentBranch = currentBranch
        self.status = status
        self.worktrees = worktrees
        self.loadedAt = loadedAt
    }

    /// Timeout of each command. Facts are refreshed from watchers; a stuck git must not pile up.
    public static let commandTimeout: Duration = .seconds(10)

    public var isDirty: Bool { status?.isDirty ?? false }
    public var isDetached: Bool { status?.isDetached ?? false }
    public var ahead: Int { status?.ahead ?? 0 }
    public var behind: Int { status?.behind ?? 0 }

    /// Loads the facts of `repo` through `client` (whose repository should be `repo`). Never throws:
    /// a command that fails or times out leaves its field `nil`, so a broken repo still shows what it can.
    ///
    /// - Parameters:
    ///   - repo: checkout folder, used for the no-git fallback on the origin URL.
    ///   - client: the repository's serial client.
    ///   - includeWorktrees: also run `git worktree list` (M2; off by default, it is one more process per refresh).
    public static func load(for repo: URL, using client: GitClient, includeWorktrees: Bool = false) async -> RepoFacts {
        let timeout = commandTimeout
        var facts = RepoFacts()

        // Origin: exit 2 + "No such remote" when missing. Without git at all, read .git/config directly.
        if let origin = try? await client.output(["remote", "get-url", "origin"], timeout: timeout), !origin.isEmpty {
            facts.originURL = origin
        } else if let origin = GitConfigReader.originURL(gitDirectory: repo.appending(path: ".git")) {
            facts.originURL = origin
        }
        facts.remote = facts.originURL.flatMap(RemoteInfo.init(remote:))

        facts.defaultBranch = await defaultBranch(using: client, timeout: timeout)

        // Status + branch in one call: the --branch header carries head / upstream / ahead-behind.
        if let result = try? await client.run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"], timeout: timeout
        ) {
            let status = GitStatus(porcelainV2: result.stdout)
            facts.status = status
            facts.currentBranch = status.branchName
        }
        if facts.currentBranch == nil, facts.status == nil,
           let branch = try? await client.output(["rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout),
           branch != "HEAD" {   // "HEAD" means detached
            facts.currentBranch = branch
        }

        if includeWorktrees, let list = try? await client.output(["worktree", "list", "--porcelain"], timeout: timeout) {
            facts.worktrees = GitWorktree.parse(list)
        }

        facts.loadedAt = .now
        return facts
    }

    /// Default branch, in order of trust:
    /// 1. `refs/remotes/origin/HEAD` (set by clone; `git remote set-head origin -a` restores it),
    /// 2. `init.defaultBranch` from config, **only when that branch exists here**,
    /// 3. an existing local (or `origin/`) `main`, then `master`.
    ///
    /// Every candidate but the first is checked against the repository, and a name that resolves to nothing is
    /// never returned. `init.defaultBranch` says what `git init` *would* create, not what this repository *has*:
    /// Xcode ships a system gitconfig setting it to `main`, so trusting it blindly answered `main` for every
    /// repository without an `origin/HEAD` — including one whose only branch is `master`, where the answer then
    /// reached `git worktree add … main` and failed with *invalid reference: main*, making a new task impossible.
    private static func defaultBranch(using client: GitClient, timeout: Duration) async -> String? {
        // origin/HEAD is a symbolic ref inside this repository: it cannot name a branch that is not there.
        if let ref = try? await client.output(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: timeout),
           let slash = ref.firstIndex(of: "/") {
            return String(ref[ref.index(after: slash)...])   // "origin/main" -> "main"
        }

        var candidates: [String] = []
        if let configured = try? await client.output(["config", "--get", "init.defaultBranch"], timeout: timeout),
           !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: ["main", "master"])

        for candidate in candidates where !candidate.isEmpty {
            for ref in ["refs/heads/\(candidate)", "refs/remotes/origin/\(candidate)"] {
                if (try? await client.run(["rev-parse", "--verify", "--quiet", ref], timeout: timeout)) != nil {
                    return candidate
                }
            }
        }
        return nil
    }
}
