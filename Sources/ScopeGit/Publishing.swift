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

    public var description: String {
        switch self {
        case .notInstalled: "gh is not installed"
        case .failed(let command, let message): "\(command) failed: \(message)"
        case .noURL: "gh returned no pull request URL"
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
