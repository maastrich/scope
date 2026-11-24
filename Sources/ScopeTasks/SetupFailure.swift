import Foundation
import ScopeCore

/// One setup command that failed, read on its own: what it printed, why it failed, and the line that says so.
///
/// A setup log holds every repository's output. Classifying the whole of it let a `401` printed by a repository that
/// succeeded, or a `conflict` in another one's tail, name the cause of a failure that was neither.
public struct SetupFailure: Sendable, Equatable {
    /// The repository as the log names it (`api`, `api@fix-login`, the scope's name for a repo scope).
    public var repo: String
    /// The command, masked; `nil` when the log was cut above its header.
    public var command: String?
    /// `exit 1`, `timed out`, `could not start`.
    public var summary: String
    public var cause: ProblemCause
    /// The line of the output that carries the cause, masked and trimmed; `nil` when no line says more than the exit.
    public var line: String?
    /// The host that line names (the registry that answered), when it names one.
    public var host: String?
    /// The HTTP status of a refusal, 401 or 403.
    public var status: Int?

    public init(repo: String, command: String?, summary: String, output: String) {
        self.repo = repo
        self.command = command.map(SetupLog.redact)
        self.summary = summary
        // Masked again whatever the caller did: nothing built from here may show a credential.
        let output = SetupLog.redact(output)
        cause = Self.cause(of: output, summary: summary)
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard cause != .exit, cause != .unknown, let index = Self.causeLine(in: lines, cause: cause) else { return }
        line = String(lines[index].prefix(Self.lineLimit))
        status = Self.status(in: lines[index])
        // uv and pip name the URL on the line above or below the one that carries the status.
        let around = [index, index - 1, index + 1, index - 2, index + 2].filter(lines.indices.contains)
        host = around.lazy.compactMap { Self.host(in: lines[$0]) }.first
    }

    /// A line can be a whole minified payload; the problem's first lines must stay readable.
    static let lineLimit = 300

    /// What the output reads as; the command's own end when it says nothing more.
    static func cause(of output: String, summary: String) -> ProblemCause {
        if summary == "timed out" { return .timeout }
        let cause = ProblemCause.classify(output)
        return cause == .unknown ? .exit : cause
    }

    /// The first line that reads as `cause`, preferring for a refusal the one with the status and a URL.
    private static func causeLine(in lines: [String], cause: ProblemCause) -> Int? {
        let candidates = lines.indices.filter { ProblemCause.classify(lines[$0]) == cause }
        guard cause == .auth else { return candidates.first }
        return candidates.first { status(in: lines[$0]) != nil && host(in: lines[$0]) != nil }
            ?? candidates.first { status(in: lines[$0]) != nil }
            ?? candidates.first
    }

    static func status(in line: String) -> Int? {
        guard let match = line.firstMatch(of: /\b(401|403)\b/) else { return nil }
        return Int(match.1)
    }

    /// The host of the first URL in `line`, without its userinfo or port.
    static func host(in line: String) -> String? {
        guard let match = line.firstMatch(of: /[A-Za-z][A-Za-z0-9+.-]*:\/\/(?:[^\s\/@]*@)?([A-Za-z0-9.-]+)/) else { return nil }
        let host = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    // MARK: What the user reads

    private var statusText: String? {
        switch status {
        case 401: "401 Unauthorized"
        case 403: "403 Forbidden"
        default: nil
        }
    }

    private var commandText: String { command.map { "`\($0)`" } ?? "the setup command" }

    /// One line saying what failed, where, and who refused: the top of the problem.
    public var headline: String {
        guard cause == .auth else { return "\(repo): \(commandText) failed (\(summary))." }
        switch (host, statusText) {
        case let (host?, status?): return "\(repo): \(host) answered \(status) to \(commandText)."
        case let (host?, nil): return "\(repo): \(host) refused the credentials of \(commandText)."
        case let (nil, status?): return "\(repo): \(commandText) was answered \(status)."
        case (nil, nil): return "\(repo): \(commandText) was refused its credentials."
        }
    }

    /// What to do about it, for a cause the user can fix outside Scope; `nil` otherwise.
    public var action: String? {
        guard cause == .auth else { return nil }
        let registry = host.map { "the login of \($0)" } ?? "the registry login"
        // Scope cannot refresh the token: it lives in the user's pip, uv or npm config, written by the registry's
        // own login command, and the setup command only reads it.
        return "The credentials were refused, most often an expired token. Refresh \(registry) "
            + "(the command that writes its token into your pip, uv or npm config), then run the setup again."
    }

    /// The headline, the line that carries the cause, and the action.
    public var explanation: String {
        var parts = [headline]
        if let line { parts.append("  " + line) }
        if let action { parts.append(action) }
        return parts.joined(separator: "\n")
    }
}

/// What a failed setup comes down to: the commands that failed, each read on its own.
public struct SetupDiagnosis: Sendable, Equatable {
    public var failures: [SetupFailure]
    /// The cause the journal and the problem both keep.
    public var cause: ProblemCause
    private var tail: String

    public init(log: String, tailLines: Int = 60) {
        failures = SetupLog.failures(in: log)
        // Masked here too: a record written before setup output was masked may be diagnosed before it is cleaned.
        tail = SetupLog.redact(SetupLog.tail(log, lines: tailLines))
        // A log with no failed command in it (a setup cut by a quit, a log cut above everything) is read by its end,
        // which is what the problem shows.
        cause = Self.primary(of: failures)?.cause ?? ProblemCause.classify(tail)
    }

    /// The failure that names the setup's cause: a refused credential first, since that is the one the user can act
    /// on and that every next task would meet again; else the first.
    public var primary: SetupFailure? { Self.primary(of: failures) }

    private static func primary(of failures: [SetupFailure]) -> SetupFailure? {
        failures.first { $0.cause == .auth } ?? failures.first
    }

    /// The problem's detail: what failed and what to do first, then the end of the log.
    public var detail: String {
        var ordered = failures
        if let index = ordered.firstIndex(where: { $0.cause == .auth }), index != 0 {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let top = ordered.map(\.explanation)
        return (top + (tail.isEmpty ? [] : [tail])).joined(separator: "\n\n")
    }
}

extension SetupLog {
    /// The commands `log` says failed, in order: what stands between a `[repo] $ command` header and its
    /// `[repo] failed: …` line (`TaskManager.runSetup`). A header the log's bound cut away leaves the output that
    /// remains, with no command.
    public static func failures(in log: String) -> [SetupFailure] {
        var failures: [SetupFailure] = []
        var repo: String?
        var command: String?
        var output: [Substring] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), let marker = line.range(of: "] $ ") {
                repo = String(line[line.index(after: line.startIndex)..<marker.lowerBound])
                command = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
                output = []
                continue
            }
            // Inside a command only its own end counts: its output may print lines of the same shape.
            let prefix = repo.map { "[\($0)] " }
            if let prefix, line == prefix + "done" {
                (repo, command, output) = (nil, nil, [])
            } else if let prefix, line.hasPrefix(prefix + "failed: ") {
                failures.append(SetupFailure(repo: repo!, command: command, summary: String(line.dropFirst(prefix.count + 8)),
                                             output: output.joined(separator: "\n")))
                (repo, command, output) = (nil, nil, [])
            } else if prefix == nil, line.hasPrefix("["), let marker = line.range(of: "] failed: ") {
                failures.append(SetupFailure(repo: String(line[line.index(after: line.startIndex)..<marker.lowerBound]),
                                             command: nil, summary: String(line[marker.upperBound...]),
                                             output: output.joined(separator: "\n")))
                output = []
            } else if prefix == nil, line.hasPrefix("["), line.hasSuffix("] done") {
                output = []
            } else {
                output.append(line)
            }
        }
        return failures
    }
}

// MARK: - Remembered per repository

/// How the last setup of each repository ended, when it failed: `<home>/setup-memory.json`.
///
/// A token that expired fails the setup of every new task the same way, and each failure used to be met as if it
/// were the first. A repository's entry is written when its setup command fails and removed when it succeeds, so
/// what is kept is always the last run.
public struct SetupMemory: Codable, Sendable, Equatable {
    /// Anything else reads as nothing remembered.
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Equatable {
        public var cause: ProblemCause
        public var host: String?
        public var status: Int?
        /// The line that carried the cause, masked.
        public var line: String?
        public var command: String?
        public var failedAt: Date
        /// The task whose setup failed, by name.
        public var task: String
        /// How many setups in a row failed for this cause.
        public var count: Int

        public init(cause: ProblemCause, host: String? = nil, status: Int? = nil, line: String? = nil, command: String? = nil,
                    failedAt: Date, task: String, count: Int = 1) {
            self.cause = cause
            self.host = host
            self.status = status
            self.line = line.map(SetupLog.redact)
            self.command = command.map(SetupLog.redact)
            self.failedAt = failedAt
            self.task = task
            self.count = count
        }
    }

    public var version: Int
    /// By base checkout path.
    public var repos: [String: Entry]

    public init(repos: [String: Entry] = [:]) {
        version = Self.currentVersion
        self.repos = repos
    }

    /// The key of a repository: its base checkout, the same for every task and every worktree of it.
    public static func key(scopeRoot: String, repo: String) -> String {
        TaskManager.baseURL(scopeRoot: scopeRoot, repoRelativePath: TaskRepo.normalize(repo)).filesystemPath
    }

    /// Takes in how one setup command ended: `failure` for a failed one, `nil` for one that succeeded.
    public mutating func record(_ failure: SetupFailure?, key: String, task: String, at date: Date = .now) {
        guard let failure else {
            repos[key] = nil
            return
        }
        let previous = repos[key]
        repos[key] = Entry(cause: failure.cause, host: failure.host, status: failure.status, line: failure.line,
                           command: failure.command, failedAt: date, task: task,
                           count: previous?.cause == failure.cause ? (previous?.count ?? 0) + 1 : 1)
    }

    /// What to say before a new task's setup runs in `repos`: one reminder per repository whose last setup was
    /// refused its credentials. Other causes are left out — a missing tool or a broken lockfile says nothing the
    /// next run will not say by itself, and may well be fixed by the very task being created.
    public func reminders(scopeRoot: String, repos names: [String], now: Date = .now) -> [SetupReminder] {
        names.compactMap { name in
            guard let entry = repos[Self.key(scopeRoot: scopeRoot, repo: name)], entry.cause == .auth else { return nil }
            return SetupReminder(repo: TaskRepo.normalize(name), entry: entry, now: now)
        }
    }
}

/// A repository whose last setup was refused its credentials, said before the next one runs.
public struct SetupReminder: Sendable, Equatable {
    public var repo: String
    public var entry: SetupMemory.Entry
    /// `today`, `yesterday`, `5 days ago`.
    public var age: String

    init(repo: String, entry: SetupMemory.Entry, now: Date) {
        self.repo = repo
        self.entry = entry
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.failedAt),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        age = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    private var refusal: String {
        let status = entry.status.map { " (\($0))" } ?? ""
        return entry.host.map { "\($0) refused the credentials\(status)" } ?? "the credentials were refused\(status)"
    }

    /// One line, for a sheet.
    public var summary: String {
        let times = entry.count > 1 ? ", \(entry.count) times in a row" : ""
        return "Last setup of \(repo) failed \(age)\(times): \(refusal)."
    }

    /// The summary, the line that carried the cause, and what to do before the setup runs again.
    public var detail: String {
        var parts = [summary]
        if let line = entry.line { parts.append("  " + line) }
        let registry = entry.host.map { "the login of \($0)" } ?? "the registry login"
        parts.append("Unless \(registry) was refreshed since, this setup fails the same way: refresh it "
            + "(the command that writes its token into your pip, uv or npm config), then run the setup again.")
        return parts.joined(separator: "\n")
    }
}

/// Owner of `<home>/setup-memory.json`. Written at the end of a setup, so straight to disk.
public struct SetupMemoryStore: Sendable {
    public let url: URL

    public init(home: URL) {
        url = ScopeHome.setupMemoryURL(home: home)
    }

    /// What is remembered; nothing when the file is missing, unreadable or from another version.
    public func load() -> SetupMemory {
        guard let memory = try? JSONStore.load(SetupMemory.self, from: url, fractionalSeconds: true),
              memory.version == SetupMemory.currentVersion else { return SetupMemory() }
        return memory
    }

    public func save(_ memory: SetupMemory) {
        do {
            try JSONStore.save(memory, to: url, fractionalSeconds: true)
        } catch {
            Log.tasks.error("setup-memory.json write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
