import Foundation
import ScopeCore

/// Failures of the commit / push helpers that are not plain git errors.
public enum PublishError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `commitAll` on a clean tree.
    case nothingToCommit
    /// `push` on a detached HEAD.
    case detachedHead

    public var description: String {
        switch self {
        case .nothingToCommit: "nothing to commit"
        case .detachedHead: "HEAD is detached; check out a branch before pushing"
        }
    }
}

/// Commit and push helpers for the Delta actions (spec §4.4).
public extension GitClient {
    /// `git add -A && git commit -m <message>`; returns the new commit sha.
    /// Throws `PublishError.nothingToCommit` when the tree is clean.
    @discardableResult
    func commitAll(message: String) async throws -> String {
        try await run(["add", "-A"], timeout: .seconds(60))
        let staged = try await run(["diff", "--cached", "--quiet"], timeout: .seconds(60), allowFailure: true)
        guard !staged.succeeded else { throw PublishError.nothingToCommit }
        try await run(["commit", "--quiet", "-m", message], timeout: .seconds(120))
        return try await output(["rev-parse", "HEAD"], timeout: .seconds(10))
    }

    /// `git push [-u] <remote> <current-branch>`. Throws `PublishError.detachedHead` when not on a branch.
    func push(remote: String = "origin", setUpstream: Bool = true, timeout: Duration? = .seconds(180)) async throws {
        let branch = try await output(["rev-parse", "--abbrev-ref", "HEAD"], timeout: .seconds(10))
        guard branch != "HEAD" else { throw PublishError.detachedHead }
        var arguments = ["push", "--quiet"]
        if setUpstream { arguments.append("-u") }
        arguments += [remote, branch]
        try await run(arguments, timeout: timeout)
    }
}

/// Failures of `GhClient`.
public enum GhError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `gh` was not found on PATH nor at the usual Homebrew locations.
    case notInstalled
    /// `gh` exited non-zero; `message` is its trimmed stderr.
    case failed(command: String, message: String)
    /// `gh` printed no URL where one was expected.
    case noURL
    /// `gh auth status` failed: `message` is its trimmed stderr / stdout.
    case notAuthenticated(message: String)
    /// `gh` printed JSON Scope could not decode.
    case invalidJSON(command: String, message: String)

    public var description: String {
        switch self {
        case .notInstalled: "gh is not installed"
        case .failed(let command, let message): "\(command) failed: \(message)"
        case .noURL: "gh returned no pull request URL"
        case .notAuthenticated(let message): "gh is not logged in: \(message)"
        case .invalidJSON(let command, let message): "\(command) returned unexpected JSON: \(message)"
        }
    }
}

/// Thin wrapper over the optional `gh` CLI (spec §6: `gh` keeps its own auth, Scope stores no token).
public struct GhClient: Sendable {
    /// Absolute path of the `gh` executable.
    public let executable: String
    /// Extra environment for every call (tests pass an isolated `HOME`).
    public var environment: [String: String]

    public init(executable: String, environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }

    /// Finds `gh` on `PATH`, then at `/opt/homebrew/bin/gh` and `/usr/local/bin/gh`. `nil` when absent.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> GhClient? {
        var candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        candidates += ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return GhClient(executable: candidate)
        }
        return nil
    }

    /// `gh pr create --title <title> --body <body>` in `checkout`; returns the PR URL.
    public func prCreate(title: String, body: String, in checkout: URL, draft: Bool = false) async throws -> URL {
        var arguments = ["pr", "create", "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        let text = try await run(arguments, in: checkout, timeout: .seconds(120))
        guard let url = Self.lastURL(in: text) else { throw GhError.noURL }
        return url
    }

    /// URL of the pull request of the current branch, `nil` when there is none.
    public func prView(in checkout: URL) async throws -> URL? {
        let result = try await Subprocess.run(
            executable: executable, arguments: ["pr", "view", "--json", "url", "--jq", ".url"],
            currentDirectory: checkout, environment: mergedEnvironment, timeout: .seconds(60)
        )
        guard result.succeeded else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.lowercased().contains("no pull requests found") { return nil }
            throw GhError.failed(command: "gh pr view", message: message)
        }
        return Self.lastURL(in: result.stdoutText)
    }

    // MARK: Pull requests (list / view / lookup)

    /// `gh auth status`: throws `GhError.notAuthenticated` when no account is logged in.
    public func checkAuth() async throws {
        let result = try await Subprocess.run(
            executable: executable, arguments: ["auth", "status"],
            environment: mergedEnvironment, timeout: .seconds(30)
        )
        guard result.succeeded else {
            let text = (result.stderrText + "\n" + result.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhError.notAuthenticated(message: text.isEmpty ? "run `gh auth login`" : text)
        }
    }

    /// Open pull requests of the repository at `checkout` (`gh pr list --state open --limit 50`), most
    /// recently updated first. `repo` (`owner/name`) overrides the remote of the checkout.
    public func prList(in checkout: URL, repo: String? = nil, limit: Int = 50) async throws -> [PullRequest] {
        var arguments = ["pr", "list", "--state", "open", "--limit", String(limit), "--json", PullRequest.jsonFields]
        if let repo { arguments += ["--repo", repo] }
        return try await runJSON(arguments, in: checkout, parse: PullRequest.parse(json:))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// One pull request by number (`gh pr view <n> --json …`).
    public func prView(number: Int, in checkout: URL, repo: String? = nil) async throws -> PullRequest {
        var arguments = ["pr", "view", String(number), "--json", PullRequest.jsonFields]
        if let repo { arguments += ["--repo", repo] }
        return try await runJSON(arguments, in: checkout, parse: PullRequest.parseOne(json:))
    }

    /// The open pull request whose head is `branch`, `nil` when there is none (`gh pr list --head <branch>`).
    public func prForBranch(_ branch: String, in checkout: URL, repo: String? = nil) async throws -> PullRequest? {
        var arguments = ["pr", "list", "--state", "open", "--head", branch, "--limit", "1", "--json", PullRequest.jsonFields]
        if let repo { arguments += ["--repo", repo] }
        return try await runJSON(arguments, in: checkout, parse: PullRequest.parse(json:)).first
    }

    // MARK: Pull request lifecycle (checks, logs, merge)

    /// The checks of pull request `number`, as its status rollup lists them.
    public func prChecks(number: Int, in checkout: URL, repo: String? = nil) async throws -> [PullRequestCheck] {
        try await prView(number: number, in: checkout, repo: repo).checkRuns
    }

    /// The log of the failed steps of an Actions run, the one job when it is known
    /// (`gh run view <run> [--job <job>] --log-failed`).
    public func failedLog(of job: ActionsJob, in checkout: URL, repo: String? = nil) async throws -> String {
        var arguments = ["run", "view", String(job.run), "--log-failed"]
        if let id = job.job { arguments += ["--job", String(id)] }
        if let repo { arguments += ["--repo", repo] }
        return try await run(arguments, in: checkout, timeout: .seconds(120))
    }

    /// The merge method the repository allows (`gh repo view --json …`), preferred as GitHub's merge button does.
    public func mergeMethod(in checkout: URL, repo: String? = nil) async throws -> MergeMethod? {
        struct Allowed: Decodable {
            var mergeCommitAllowed: Bool?
            var squashMergeAllowed: Bool?
            var rebaseMergeAllowed: Bool?
        }
        var arguments = ["repo", "view"]
        if let repo { arguments.append(repo) }
        arguments += ["--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"]
        let allowed = try await runJSON(arguments, in: checkout) { try JSONDecoder().decode(Allowed.self, from: $0) }
        return MergeMethod.preferred(mergeCommit: allowed.mergeCommitAllowed ?? false, squash: allowed.squashMergeAllowed ?? false,
                                     rebase: allowed.rebaseMergeAllowed ?? false)
    }

    /// `gh pr merge <n> --<method>`. Branches are left alone: deleting one is the task's close, which knows the
    /// branch it created rather than guessing.
    public func prMerge(number: Int, method: MergeMethod, in checkout: URL, repo: String? = nil) async throws {
        var arguments = ["pr", "merge", String(number), "--\(method.rawValue)"]
        if let repo { arguments += ["--repo", repo] }
        _ = try await run(arguments, in: checkout, timeout: .seconds(120))
    }

    private func runJSON<T>(_ arguments: [String], in checkout: URL, parse: (Data) throws -> T) async throws -> T {
        let command = "gh " + arguments.prefix(2).joined(separator: " ")
        let result = try await Subprocess.run(
            executable: executable, arguments: arguments, currentDirectory: checkout,
            environment: mergedEnvironment, timeout: .seconds(60)
        )
        guard result.succeeded else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.lowercased().contains("gh auth login"), !message.lowercased().contains("none of the git remotes") {
                throw GhError.notAuthenticated(message: message)
            }
            throw GhError.failed(command: command, message: message)
        }
        do { return try parse(result.stdout) } catch {
            throw GhError.invalidJSON(command: command, message: String(describing: error))
        }
    }

    private var mergedEnvironment: [String: String] {
        ProcessInfo.processInfo.environment
            .merging(["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]) { $1 }
            .merging(environment) { $1 }
    }

    private func run(_ arguments: [String], in checkout: URL, timeout: Duration) async throws -> String {
        let result = try await Subprocess.run(
            executable: executable, arguments: arguments, currentDirectory: checkout,
            environment: mergedEnvironment, timeout: timeout
        )
        guard result.succeeded else {
            throw GhError.failed(
                command: "gh " + arguments.prefix(2).joined(separator: " "),
                message: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdoutText
    }

    /// The last `http(s)://` token of `text`.
    static func lastURL(in text: String) -> URL? {
        text.split(whereSeparator: \.isWhitespace)
            .reversed()
            .first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            .flatMap { URL(string: String($0)) }
    }
}
