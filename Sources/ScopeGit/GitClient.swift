import Foundation
import ScopeCore

/// One `GitClient` per repository. Every git invocation for that repository runs one at a time.
///
/// Actors are re-entrant: two concurrent `await client.run(...)` calls both enter the actor and
/// interleave at the `await` on the subprocess, so the actor alone does not serialise anything.
/// The explicit `tail` task chain does [verified]. Each command:
///
/// 1. waits for the previous command on this client to finish, whatever its outcome,
/// 2. then takes a permit from the shared `AsyncSemaphore` (global cap across all repos),
/// 3. runs the process and releases the permit.
///
/// Waiting for the chain *before* taking the permit means a queued command never holds a global
/// permit while it is idle behind another command of the same repository.
public actor GitClient {
    /// Working directory of every command (`git` runs with this as its current directory).
    public nonisolated let repository: URL
    /// Absolute path of the git executable (`GitLocator` finds it).
    public nonisolated let gitPath: String

    private let environment: [String: String]
    private let semaphore: AsyncSemaphore?
    private var tail: Task<Void, Never> = Task {}

    /// Environment applied to every command, on top of the process environment:
    /// - `LC_ALL=C`: stable, parseable English output
    /// - `GIT_TERMINAL_PROMPT=0`: never hang asking for credentials
    /// - `GIT_OPTIONAL_LOCKS=0`: `status` does not take `index.lock`, so an agent's own git is never blocked by us
    public static let baseEnvironment: [String: String] = [
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
    ]

    /// - Parameters:
    ///   - repository: working directory for every command.
    ///   - gitPath: absolute path of the git executable.
    ///   - environment: extra variables merged over `baseEnvironment` for every command (tests pass `HOME`, `GIT_CONFIG_GLOBAL`).
    ///   - semaphore: shared fan-out guard; `nil` means no global limit (tests, one-off clients).
    public init(
        repository: URL,
        gitPath: String = "/usr/bin/git",
        environment: [String: String] = [:],
        semaphore: AsyncSemaphore? = nil
    ) {
        self.repository = repository
        self.gitPath = gitPath
        self.environment = environment
        self.semaphore = semaphore
    }

    /// Runs `git <arguments>` in the repository, after every command previously queued on this client.
    ///
    /// - Parameters:
    ///   - arguments: git arguments, without the executable.
    ///   - environment: per-call variables, merged over the client environment.
    ///   - timeout: the process is killed and `SubprocessError.timedOut` is thrown when it runs longer.
    ///   - allowFailure: when `false` (default) a non-zero exit throws `GitError`; when `true` the result is returned as is.
    /// - Throws: `GitError`, `SubprocessError`, or `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration? = .seconds(60),
        allowFailure: Bool = false
    ) async throws -> ProcessResult {
        let previous = tail
        let repository = repository
        let gitPath = gitPath
        let semaphore = semaphore
        let mergedEnvironment = Self.baseEnvironment
            .merging(self.environment) { $1 }
            .merging(environment) { $1 }

        let work = Task<ProcessResult, any Error> {
            await previous.value            // the previous command is fully finished, whatever happened to it
            try Task.checkCancellation()    // cancelled while queued: do not spawn at all
            return try await Self.execute(
                gitPath: gitPath, arguments: arguments, repository: repository,
                environment: mergedEnvironment, timeout: timeout, semaphore: semaphore
            )
        }
        tail = Task { _ = try? await work.value }

        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()                   // propagate structured cancellation into the unstructured task
        }

        if !allowFailure && !result.succeeded {
            let error = GitError(arguments: arguments, result: result)
            Log.git.debug("\(error.description, privacy: .public) in \(repository.path, privacy: .public)")
            throw error
        }
        return result
    }

    /// Convenience: stdout of a successful command, trimmed of surrounding whitespace and newlines.
    public func output(_ arguments: [String], timeout: Duration? = .seconds(60)) async throws -> String {
        try await run(arguments, timeout: timeout)
            .stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the process under the shared permit when there is one.
    private static func execute(
        gitPath: String,
        arguments: [String],
        repository: URL,
        environment: [String: String],
        timeout: Duration?,
        semaphore: AsyncSemaphore?
    ) async throws -> ProcessResult {
        guard let semaphore else {
            return try await Subprocess.run(
                executable: gitPath, arguments: arguments, currentDirectory: repository,
                environment: environment, timeout: timeout
            )
        }
        return try await semaphore.withPermit {
            try await Subprocess.run(
                executable: gitPath, arguments: arguments, currentDirectory: repository,
                environment: environment, timeout: timeout
            )
        }
    }
}
