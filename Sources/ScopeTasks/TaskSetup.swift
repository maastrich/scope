import Foundation

/// Where a task's setup command is (spec §4.3): run once in each new sandbox, before the first thread starts.
public enum SetupState: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// No setup was asked for yet, or the record predates setup.
    case notRun
    case running
    case succeeded
    case failed
    /// There was nothing to run, or the user unticked "Run setup".
    case skipped

    /// A setup cut short by a quit cannot be picked up again: its process is gone, so the next launch reports it
    /// as failed rather than leaving a spinner that never stops. Every other state is kept.
    public var normalizedAfterRestart: SetupState {
        self == .running ? .failed : self
    }
}

/// The setup of a task as its record keeps it: the state and the output of the last run.
public struct TaskSetupRecord: Codable, Sendable, Equatable {
    public var state: SetupState
    /// What the commands printed, one `$ command` header per repository; bounded by `SetupLog.limit`.
    public var log: String
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(state: SetupState, log: String = "", startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.state = state
        self.log = log
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// See `SetupState.normalizedAfterRestart`; the log says why.
    public var normalizedAfterRestart: TaskSetupRecord {
        guard state == .running else { return self }
        var record = self
        record.state = .failed
        record.log = SetupLog.append("\n[interrupted: Scope quit while the setup was running]\n", to: log)
        return record
    }
}

/// Keeps a command log to its last `limit` characters. A setup that loops can print megabytes; the task record
/// is a small JSON file read at every launch, and the end of a log is where the error is.
public enum SetupLog {
    public static let limit = 64 * 1024
    static let cutMarker = "[… earlier output dropped …]\n"

    public static func append(_ text: String, to log: String, limit: Int = SetupLog.limit) -> String {
        bounded(log + text, limit: limit)
    }

    public static func bounded(_ text: String, limit: Int = SetupLog.limit) -> String {
        guard text.count > limit else { return text }
        return cutMarker + String(text.suffix(max(0, limit - cutMarker.count)))
    }

    /// The last `lines` lines, for a problem's detail.
    public static func tail(_ text: String, lines: Int = 40) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// The commands a log says were run — the `[repo] $ command` headers `TaskManager.runSetup` writes — each once,
    /// in order. What the Environment card shows beside *Setup* for a task whose commands are not resolved yet.
    public static func commands(in log: String) -> [String] {
        var seen = Set<String>()
        var commands: [String] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), let marker = line.range(of: "] $ ") else { continue }
            let command = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if !command.isEmpty, seen.insert(command).inserted { commands.append(command) }
        }
        return commands
    }

    /// The lines of `log` that say a command was not run because the repository's files rule it out
    /// (`TaskManager.runSetup`).
    public static func skippedCommands(in log: String) -> [String] {
        log.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            line.hasPrefix("[") && line.contains("] skipped `")
        }
    }

    /// The files a setup did not copy, one line per reason. A repository that commits its skills as symlinks used to
    /// get one line per skill — thirty lines of the same sentence above the command that actually failed.
    public static func refusals(_ refusals: [SandboxFileCopy.Refusal], repo name: String) -> String {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        for refusal in refusals {
            if paths[refusal.reason] == nil { order.append(refusal.reason) }
            paths[refusal.reason, default: []].append(refusal.path)
        }
        return order.map { reason in
            let list = paths[reason]!
            guard list.count > 2 else {
                return list.map { "[\(name)] did not copy \($0): \(reason)\n" }.joined()
            }
            return "[\(name)] did not copy \(list.count) paths (\(list.prefix(2).joined(separator: ", ")) and \(list.count - 2) more): \(reason)\n"
        }.joined()
    }
}

/// The setup and teardown commands of one repository of a task, and the files copied into its sandbox.
public struct SandboxCommands: Sendable, Equatable {
    public var setup: String?
    public var teardown: String?
    /// Globs relative to the base checkout, copied into the sandbox before the setup runs.
    public var copyFiles: [String]

    /// What Scope copies when nothing says otherwise: the environment files a repository keeps out of git.
    public static let defaultCopyFiles = [".env*"]

    public init(setup: String? = nil, teardown: String? = nil, copyFiles: [String] = SandboxCommands.defaultCopyFiles) {
        self.setup = setup
        self.teardown = teardown
        self.copyFiles = copyFiles
    }

    /// The graph card's commands, overridden field by field by the scope's config. An override set to an empty
    /// string turns the card's command off; an absent one leaves it.
    public static func resolve(card: RepoContextSummary?, setupOverride: String?, teardownOverride: String?,
                               copyFilesOverride: [String]?) -> SandboxCommands {
        func pick(_ override: String?, _ card: String?) -> String? {
            let chosen = override ?? card
            let trimmed = chosen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return SandboxCommands(
            setup: pick(setupOverride, card?.setup),
            teardown: pick(teardownOverride, card?.teardown),
            copyFiles: copyFilesOverride ?? defaultCopyFiles
        )
    }
}

/// The variables a setup or teardown command runs with, on top of the login-shell environment.
public enum SandboxEnvironment {
    public static func variables(task: TaskRecord, repo: TaskRepo, basePath: String, defaultBranch: String?) -> [String: String] {
        var variables = [
            "SCOPE_TASK": task.slug,
            "SCOPE_TASK_ROOT": task.root,
            "SCOPE_SCOPE": task.scopeSlug,
            "SCOPE_SANDBOX": repo.sandboxPath,
            "SCOPE_BASE_PATH": basePath,
        ]
        if let defaultBranch { variables["SCOPE_DEFAULT_BRANCH"] = defaultBranch }
        if let port = task.portBase { variables["SCOPE_PORT"] = String(port) }
        return variables
    }
}

/// Hands each task a block of ports of its own, so two tasks running the same dev server do not fight over 3000.
///
/// The block's first port is `SCOPE_PORT`; the task may use it and the nine after it. The base is stored on the
/// record, so it survives restarts, and allocated against the live tasks only: an archived task's block is free.
public enum PortAllocator {
    public static let blockSize = 10
    /// Clear of the usual dev-server ports (3000, 5173, 8080…) and below the ephemeral range macOS hands out.
    public static let range = 41000..<49000

    /// What a Debug build hands out instead. Each app only knows the tasks of its own home, so with one range
    /// both gave their first task 41000 and the two dev servers fought over it — the very thing a block exists
    /// to prevent. Same width, clear of `range` and of the usual dev-server ports.
    public static let debugRange = 31000..<39000

    /// The range an app build allocates from.
    public static func range(debugBuild: Bool) -> Range<Int> { debugBuild ? debugRange : range }

    /// The lowest block start in `range` no base in `taken` overlaps; `nil` once every block is used.
    public static func allocate(taken: some Sequence<Int>, in range: Range<Int> = PortAllocator.range) -> Int? {
        let used = Set(taken.map { $0 - (($0 - range.lowerBound) % blockSize) })
        return stride(from: range.lowerBound, to: range.upperBound, by: blockSize).first { !used.contains($0) }
    }
}
