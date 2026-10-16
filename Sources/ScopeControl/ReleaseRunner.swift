import Foundation
import ScopeCore
import Synchronization

/// The version a release names, as `scripts/release.sh` accepts it: `X.Y.Z`, or `X.Y.Z-pre.N`, never with the `v`.
public enum ReleaseVersion {
    public static func isValid(_ version: String) -> Bool {
        version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/) != nil
    }

    /// `v1.2.3` → `1.2.3`; anything else as it came.
    public static func stripped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }
}

/// One process the release needs to run: git, gh, bash or git-cliff, by absolute path.
public struct ReleaseCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var directory: URL?

    public init(_ executable: String, _ arguments: [String], in directory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
    }

    /// `git fetch origin main`, for a log line or a test.
    public var line: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

/// What a `ReleaseCommand` did.
public struct ReleaseCommandOutcome: Sendable, Equatable {
    /// `nil` when the process never ran or was killed by the timeout.
    public var exitCode: Int32?
    /// stdout and stderr, interleaved as they came.
    public var output: String
    public var timedOut: Bool

    public init(exitCode: Int32?, output: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// `exit 1`, `timed out`, `could not start`.
    public var summary: String {
        if timedOut { return "timed out" }
        guard let exitCode else { return "could not start" }
        return "exit \(exitCode)"
    }
}

/// Runs the processes of a release. Injected so the runner is testable with a double that answers scripted
/// outcomes and records what was asked.
public protocol ReleaseCommandRunner: Sendable {
    /// Runs `command` with `environment` (the whole environment, not a delta), feeding `onOutput` every chunk the
    /// process prints as it prints it, and answers once it is over.
    func run(_ command: ReleaseCommand, environment: [String: String], timeout: Duration,
             onOutput: @escaping @Sendable (String) -> Void) async -> ReleaseCommandOutcome
}

/// What `gh run list` says about a commit, folded into one answer.
public enum ReleaseCIVerdict: Sendable, Equatable {
    /// Every completed run passed (or was skipped).
    case green(runs: Int)
    /// GitHub knows no run for the commit: a repository without CI, or one whose workflows have not started yet.
    case noRuns
    /// Some runs have not finished.
    case pending([String])
    /// Some runs failed, were cancelled or need someone.
    case failed([String])

    /// One line for the result's `ci` field.
    public var line: String {
        switch self {
        case .green(let runs): "green (\(runs) \(runs == 1 ? "run" : "runs"))"
        case .noRuns: "no runs"
        case .pending(let names): "still running: " + names.joined(separator: ", ")
        case .failed(let names): "red: " + names.joined(separator: ", ")
        }
    }
}

/// Reads what `gh run list --json name,status,conclusion,event,workflowName,headBranch` prints.
public enum ReleaseCI {
    struct Run: Decodable {
        var name: String?
        var status: String?
        var conclusion: String?
        var event: String?
        var workflowName: String?
        var headBranch: String?

        var label: String { workflowName ?? name ?? "a workflow" }
    }

    static func runs(from json: Data) throws -> [Run] {
        try JSONDecoder().decode([Run].self, from: json)
    }

    /// The verdict on the runs of one commit.
    public static func verdict(json: Data) throws -> ReleaseCIVerdict {
        let runs = try runs(from: json)
        guard !runs.isEmpty else { return .noRuns }
        let failed = runs.filter { ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"].contains($0.conclusion ?? "") }
        if !failed.isEmpty { return .failed(failed.map(\.label)) }
        let pending = runs.filter { $0.status != "completed" }
        if !pending.isEmpty { return .pending(pending.map(\.label)) }
        return .green(runs: runs.count)
    }

    /// The release workflows among a list of unfinished runs: a workflow whose name says *release*, or any run a tag
    /// push started (GitHub puts the tag where the branch would be).
    public static func releaseRuns(json: Data) throws -> [String] {
        try runs(from: json).filter { run in
            run.label.lowercased().contains("release")
                || (run.event == "push" && (run.headBranch ?? "").hasPrefix("v")
                    && (run.headBranch ?? "").dropFirst().first?.isNumber == true)
        }.map { "\($0.label) on \($0.headBranch ?? "?")" }
    }
}

/// The last `limit` bytes of what a process printed, so a chatty script cannot grow the answer without bound.
struct BoundedOutput: Sendable {
    private(set) var text = ""
    private(set) var truncated = false
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ chunk: String) {
        text += chunk
        guard text.utf8.count > limit else { return }
        truncated = true
        var tail = String(decoding: text.utf8.suffix(limit), as: UTF8.self)
        // Start on a whole line.
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        text = tail
    }
}

/// The repository a release is cut from.
public struct ReleaseTarget: Sendable, Equatable {
    /// Relative to the scope root (`.` for a repository that is the scope).
    public var repo: String
    public var scopeSlug: String
    /// Where to clone from: the repository's `origin`.
    public var originURL: String
    /// The folder under `<home>/releases/` and the name in the tag's message: `owner-repo` from the remote, or the
    /// folder's name.
    public var name: String

    public init(repo: String, scopeSlug: String, originURL: String, name: String) {
        self.repo = repo
        self.scopeSlug = scopeSlug
        self.originURL = originURL
        self.name = name
    }
}

/// Cuts a release the way the user would from a clean, up-to-date `main` — in a clone of the app's own, with the
/// app's processes, so it works from a thread whose sandbox hooks would refuse the push, and never touches the
/// user's checkout.
///
/// The steps, each one a refusal when it fails: the remote's default branch (`git ls-remote --symref`), the clone
/// under `<home>/releases/` (reused: fetched and reset), CI on the head and no release already running (`gh run
/// list`, when `gh` exists), then the repository's `scripts/release.sh` — or, without one, what it does: the next
/// version from `git cliff --bumped-version`, an annotated tag, a push of the tag. The script's output comes back
/// as it is printed and in the answer, bounded.
public struct ReleaseRunner: Sendable {
    public var home: URL
    public var gitPath: String
    /// `nil` skips the CI checks and says so in the answer.
    public var ghPath: String?
    /// `nil` makes the fallback need an explicit version.
    public var cliffPath: String?
    public var bashPath: String
    /// The user's login-shell environment: their PATH (git-cliff, gh), their credential helpers, their ssh agent.
    public var environment: [String: String]
    public var runner: any ReleaseCommandRunner

    /// How much of the script's output the answer keeps.
    public static let outputLimit = 32 * 1024
    public static let cloneTimeout: Duration = .seconds(300)
    public static let scriptTimeout: Duration = .seconds(600)
    public static let scriptPath = "scripts/release.sh"

    public init(home: URL, gitPath: String, ghPath: String? = nil, cliffPath: String? = nil, bashPath: String = "/bin/bash",
                environment: [String: String], runner: any ReleaseCommandRunner) {
        self.home = home
        self.gitPath = gitPath
        self.ghPath = ghPath
        self.cliffPath = cliffPath
        self.bashPath = bashPath
        self.environment = environment
        self.runner = runner
    }

    private var fileManager: FileManager { .default }

    /// `<home>/releases/<name>`
    public func checkout(for target: ReleaseTarget) -> URL {
        ScopeHome.releasesURL(home: home).appending(path: target.name, directoryHint: .isDirectory)
    }

    /// The environment every command runs with: the user's, without what a Scope thread would have injected —
    /// `SCOPE_*` would make `scope` and the hooks believe the release runs in a task — and with every prompt off.
    public var commandEnvironment: [String: String] {
        var result = environment.filter { !$0.key.hasPrefix("SCOPE_") }
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["GH_PROMPT_DISABLED"] = "1"
        result["GH_NO_UPDATE_NOTIFIER"] = "1"
        result["TERM"] = "dumb"
        result["NO_COLOR"] = "1"
        result["CLICOLOR"] = "0"
        return result
    }

    /// `ref: refs/heads/main\tHEAD` → `main`; `nil` when the remote names no default branch.
    public static func defaultBranch(fromLsRemote output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[1] == "HEAD", parts[0].hasPrefix("ref: refs/heads/") else { continue }
            let branch = parts[0].dropFirst("ref: refs/heads/".count)
            return branch.isEmpty ? nil : String(branch)
        }
        return nil
    }

    /// The tag the script named: `Release notes for v0.4.0 (...)` in a dry run, `v0.4.0 pushed.` otherwise.
    public static func tag(inScriptOutput output: String) -> String? {
        let pattern = /(?:Release notes for |==> )(v[0-9]+\.[0-9]+\.[0-9]+[-0-9A-Za-z.]*)/
        return output.firstMatch(of: pattern).map { String($0.1) }
    }

    public func release(_ target: ReleaseTarget, params: ReleaseParams,
                        progress: @escaping @Sendable (String) -> Void) async -> Result<ReleaseResult, ControlError> {
        if let version = params.version, !ReleaseVersion.isValid(version) {
            return .failure(.badRequest("“\(version)” is not a version", detail: "Expected X.Y.Z or X.Y.Z-pre.N, without the v."))
        }
        let checkout = checkout(for: target)
        let environment = commandEnvironment

        // 1. The default branch, from the remote itself: a clone of a repository without one releases nothing.
        let symref = await run(ReleaseCommand(gitPath, ["ls-remote", "--symref", target.originURL, "HEAD"]),
                               environment: environment, timeout: .seconds(60))
        guard symref.succeeded else {
            return .failure(.failed("could not reach the origin of \(target.repo)", detail: symref.output.trimmed))
        }
        guard let branch = Self.defaultBranch(fromLsRemote: symref.output) else {
            return .failure(.failed("the origin of \(target.repo) has no default branch",
                                    detail: "A release is cut from origin/<default>; set one on the remote first."))
        }

        // 2. The clone, or the one left by the last release brought back to origin/<branch> exactly.
        let reuse = fileManager.fileExists(atPath: checkout.appending(path: ".git").path)
        progress(reuse ? "fetching origin/\(branch) of \(target.repo) into \(checkout.path)"
                       : "cloning origin/\(branch) of \(target.repo) into \(checkout.path)")
        let steps: [ReleaseCommand] = reuse
            ? [ReleaseCommand(gitPath, ["remote", "set-url", "origin", target.originURL], in: checkout),
               ReleaseCommand(gitPath, ["fetch", "--quiet", "--prune", "--prune-tags", "--tags", "--force", "origin", branch], in: checkout),
               ReleaseCommand(gitPath, ["checkout", "--quiet", "-B", branch, "origin/\(branch)"], in: checkout),
               ReleaseCommand(gitPath, ["reset", "--quiet", "--hard", "origin/\(branch)"], in: checkout),
               ReleaseCommand(gitPath, ["clean", "--quiet", "-fdx"], in: checkout)]
            : [ReleaseCommand(gitPath, ["clone", "--quiet", "--filter=blob:none", "--branch", branch, "--single-branch",
                                        target.originURL, checkout.path])]
        if !reuse {
            do {
                try fileManager.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return .failure(.failed("could not create \(checkout.deletingLastPathComponent().path)", detail: String(describing: error)))
            }
        }
        for step in steps {
            let outcome = await run(step, environment: environment, timeout: Self.cloneTimeout)
            guard outcome.succeeded else {
                return .failure(.failed("\(step.line) failed (\(outcome.summary))", detail: outcome.output.trimmed))
            }
        }
        let headOutcome = await run(ReleaseCommand(gitPath, ["rev-parse", "HEAD"], in: checkout), environment: environment, timeout: .seconds(30))
        guard headOutcome.succeeded else {
            return .failure(.failed("could not read the head of \(checkout.path)", detail: headOutcome.output.trimmed))
        }
        let head = headOutcome.output.trimmed

        // 3. CI on that head, and no release already on its way.
        var ci: String
        if let ghPath {
            progress("checking CI on \(head.prefix(12))")
            let fields = "name,status,conclusion,event,workflowName,headBranch"
            for status in ["in_progress", "queued"] {
                let running = await run(ReleaseCommand(ghPath, ["run", "list", "--status", status, "--limit", "50", "--json", fields], in: checkout),
                                        environment: environment, timeout: .seconds(60))
                guard running.succeeded else {
                    guard params.force else {
                        return .failure(.failed("could not ask GitHub about the running workflows of \(target.repo)",
                                                detail: running.output.trimmed + "\n--force releases without the check."))
                    }
                    break
                }
                let releases = (try? ReleaseCI.releaseRuns(json: Data(running.output.utf8))) ?? []
                if !releases.isEmpty {
                    return .failure(.failed("a release of \(target.repo) is already running",
                                            detail: releases.joined(separator: "\n") + "\nWait for it, or cancel it on GitHub."))
                }
            }
            let runs = await run(ReleaseCommand(ghPath, ["run", "list", "--commit", head, "--limit", "50", "--json", fields], in: checkout),
                                 environment: environment, timeout: .seconds(60))
            if runs.succeeded, let verdict = try? ReleaseCI.verdict(json: Data(runs.output.utf8)) {
                switch verdict {
                case .green, .noRuns:
                    ci = verdict.line
                case .pending, .failed:
                    guard params.force else {
                        return .failure(.failed("CI on \(head.prefix(12)) is not green: \(verdict.line)",
                                                detail: "Wait for it, fix it, or release anyway with --force."))
                    }
                    ci = verdict.line + " (forced)"
                }
            } else {
                guard params.force else {
                    return .failure(.failed("could not read CI for \(head.prefix(12))",
                                            detail: runs.output.trimmed + "\n--force releases without the check."))
                }
                ci = "not checked: gh failed (forced)"
            }
        } else {
            ci = "not checked: gh is not installed"
        }

        // 4. The repository's own script, or what it does.
        var output = BoundedOutput(limit: Self.outputLimit)
        let script = checkout.appending(path: Self.scriptPath, directoryHint: .notDirectory)
        if fileManager.isExecutableFile(atPath: script.path) || fileManager.fileExists(atPath: script.path) {
            var arguments = [script.path]
            if let version = params.version { arguments.append(version) }
            arguments.append("--yes")
            if params.dryRun { arguments.append("--dry-run") }
            progress((params.dryRun ? "previewing" : "running") + " \(Self.scriptPath)" + (params.version.map { " \($0)" } ?? ""))
            let outcome = await runner.run(ReleaseCommand(bashPath, arguments, in: checkout), environment: environment,
                                           timeout: Self.scriptTimeout) { chunk in
                for line in chunk.split(whereSeparator: \.isNewline) where !line.trimmed.isEmpty {
                    progress(String(line.prefix(400)))
                }
            }
            output.append(outcome.output)
            guard outcome.succeeded else {
                return .failure(.failed("\(Self.scriptPath) failed (\(outcome.summary))", detail: output.text.trimmed))
            }
            let tag = params.version.map { "v\($0)" } ?? Self.tag(inScriptOutput: outcome.output)
            return .success(ReleaseResult(repo: target.repo, scopeSlug: target.scopeSlug, branch: branch, head: head, tag: tag,
                                          released: !params.dryRun, dryRun: params.dryRun, method: Self.scriptPath,
                                          checkout: checkout.path, ci: ci, output: output.text, truncated: output.truncated))
        }

        // No script: version from git-cliff, an annotated tag, the tag pushed. Nothing is committed on the branch.
        var version = params.version
        if version == nil {
            guard let cliffPath else {
                return .failure(.failed("\(target.repo) has no \(Self.scriptPath) and git-cliff is not installed",
                                        detail: "Give the version to release, or `brew install git-cliff` so Scope can compute it."))
            }
            let bumped = await run(ReleaseCommand(cliffPath, ["--bumped-version"], in: checkout), environment: environment, timeout: .seconds(120))
            guard bumped.succeeded else {
                return .failure(.failed("git cliff --bumped-version failed (\(bumped.summary))", detail: bumped.output.trimmed))
            }
            let candidate = ReleaseVersion.stripped(bumped.output)
            guard ReleaseVersion.isValid(candidate) else {
                return .failure(.failed("git-cliff proposed “\(candidate)”, which is not a version"))
            }
            version = candidate
        }
        guard let version else { return .failure(.failed("no version to release")) }
        let tag = "v\(version)"
        let existing = await run(ReleaseCommand(gitPath, ["ls-remote", "--tags", "origin", "refs/tags/\(tag)"], in: checkout),
                                 environment: environment, timeout: .seconds(60))
        guard existing.succeeded else {
            return .failure(.failed("could not list the tags of \(target.repo)", detail: existing.output.trimmed))
        }
        guard existing.output.trimmed.isEmpty else {
            return .failure(.failed("tag \(tag) already exists on origin"))
        }
        var notes = ""
        if let cliffPath {
            let generated = await run(ReleaseCommand(cliffPath, ["--unreleased", "--tag", tag, "--strip", "all"], in: checkout),
                                      environment: environment, timeout: .seconds(120))
            if generated.succeeded { notes = generated.output.trimmed }
        }
        output.append("Plan: annotated tag \(tag) on \(branch) @ \(head.prefix(12)), pushed to origin (no commit, no changelog: \(Self.scriptPath) is absent)\n")
        if !notes.isEmpty { output.append("\n\(notes)\n") }
        if params.dryRun {
            output.append("--dry-run: nothing changed\n")
            return .success(ReleaseResult(repo: target.repo, scopeSlug: target.scopeSlug, branch: branch, head: head, tag: tag,
                                          released: false, dryRun: true, method: "git tag", checkout: checkout.path, ci: ci,
                                          output: output.text, truncated: output.truncated))
        }
        progress("tagging \(tag) and pushing it")
        var tagArguments = ["tag", "-a", "--cleanup=verbatim", tag, "-m", "\(target.name) \(version)"]
        if !notes.isEmpty { tagArguments += ["-m", notes] }
        for step in [ReleaseCommand(gitPath, tagArguments, in: checkout),
                     ReleaseCommand(gitPath, ["push", "origin", "refs/tags/\(tag)"], in: checkout)] {
            let outcome = await run(step, environment: environment, timeout: Self.cloneTimeout)
            output.append(outcome.output)
            guard outcome.succeeded else {
                return .failure(.failed("\(step.line) failed (\(outcome.summary))", detail: output.text.trimmed))
            }
        }
        output.append("\(tag) pushed.\n")
        return .success(ReleaseResult(repo: target.repo, scopeSlug: target.scopeSlug, branch: branch, head: head, tag: tag,
                                      released: true, dryRun: false, method: "git tag", checkout: checkout.path, ci: ci,
                                      output: output.text, truncated: output.truncated))
    }

    private func run(_ command: ReleaseCommand, environment: [String: String], timeout: Duration) async -> ReleaseCommandOutcome {
        await runner.run(command, environment: environment, timeout: timeout) { _ in }
    }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The real runner: `Foundation.Process`, both pipes merged into one so the answer reads like the terminal would,
/// each chunk handed on as it arrives.
public struct ProcessReleaseRunner: ReleaseCommandRunner {
    public init() {}

    public func run(_ command: ReleaseCommand, environment: [String: String], timeout: Duration,
                    onOutput: @escaping @Sendable (String) -> Void) async -> ReleaseCommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let sink = OutputSink()
        let box = ProcessHold(process: process, pipe: pipe)
        let completion = ProcessRunState()

        let result: ReleaseCommandOutcome = await withCheckedContinuation { continuation in
            let settle: @Sendable (ProcessRunCompletion.Event) -> Void = { event in
                guard let status = completion.record(event) else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                box.release()
                continuation.resume(returning: ReleaseCommandOutcome(
                    exitCode: status == .timedOut ? nil : status.code,
                    output: String(decoding: sink.take(), as: UTF8.self),
                    timedOut: status == .timedOut))
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    settle(.outputClosed)
                } else {
                    sink.append(data)
                    onOutput(String(decoding: data, as: UTF8.self))
                }
            }
            process.terminationHandler = { finished in
                settle(.terminated(code: finished.terminationStatus, signalled: finished.terminationReason == .uncaughtSignal))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                box.release()
                continuation.resume(returning: ReleaseCommandOutcome(exitCode: nil, output: String(describing: error)))
                return
            }
            let pid = process.processIdentifier
            Task {
                try? await Task.sleep(for: timeout)
                guard completion.markTimedOut() else { return }
                kill(pid, SIGTERM)
            }
        }
        return result
    }
}

/// Collects what the process printed, from the pipe's private queue.
final class OutputSink: Sendable {
    private let storage = Mutex(Data())

    func append(_ data: Data) { storage.withLock { $0.append(data) } }
    func take() -> Data { storage.withLock { $0 } }
}

/// Keeps the `Process` and its `Pipe` alive until the pipe reports its end: Foundation lets go of a finished process,
/// and with it the readability source that would deliver EOF (see `ProcessBox` in ScopeCore). Retained only.
final class ProcessHold: @unchecked Sendable {
    let process: Process
    let pipe: Pipe

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }

    func release() { process.terminationHandler = nil }
}

/// `ProcessRunCompletion` behind a lock, as a reference the pipe's queue, the termination handler and the timeout task
/// can all share.
final class ProcessRunState: Sendable {
    private let state = Mutex(ProcessRunCompletion())

    /// The status to resume with, once — `nil` every other time.
    func record(_ event: ProcessRunCompletion.Event) -> ProcessRunCompletion.Status? {
        state.withLock { $0.record(event) ? $0.status : nil }
    }

    func markTimedOut() -> Bool {
        state.withLock { $0.markTimedOut() }
    }
}

/// When the one continuation of `ProcessReleaseRunner.run` resumes: once the process has terminated and its pipe
/// has closed, or terminated after a timeout (a grandchild may hold the pipe).
struct ProcessRunCompletion: Sendable {
    enum Event: Sendable {
        case outputClosed
        case terminated(code: Int32, signalled: Bool)
    }

    enum Status: Sendable, Equatable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut

        var code: Int32? {
            switch self {
            case .exited(let code): code
            case .signalled, .timedOut: nil
            }
        }
    }

    private(set) var outputClosed = false
    private(set) var status: Status?
    private(set) var timedOut = false
    private(set) var resumed = false

    /// `true` to resume now, at most once.
    mutating func record(_ event: Event) -> Bool {
        switch event {
        case .outputClosed: outputClosed = true
        case .terminated(let code, let signalled):
            if status == nil { status = timedOut ? .timedOut : (signalled ? .signalled(code) : .exited(code)) }
        }
        guard !resumed, status != nil, outputClosed || timedOut else { return false }
        resumed = true
        return true
    }

    /// `true` when the process is still running and should be killed.
    mutating func markTimedOut() -> Bool {
        guard status == nil, !resumed else { return false }
        timedOut = true
        return true
    }
}
