import Foundation

/// One thing that happened inside Scope, as `SCOPE_HOME/logs/events-YYYY-MM.jsonl` keeps it: one JSON object per line.
///
/// The journal is for improving the app, read by whoever runs the next analysis: lifecycle, problems, recoveries,
/// refusals and how long things took. It is narrow on purpose. Every string field goes through `JournalEvent.token`,
/// which keeps ids, scope slugs, enum values and versions and turns anything else — a path, a title, a prompt, a
/// message — into `redacted`. A Problem keeps the literal text of its title, never what was interpolated into it.
public struct JournalEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The app started. `version`; `outcome` how the previous session ended (`SessionEnd`), `previous` its
        /// version and `seconds` its length; `count` the threads restored; `cause` `shift` when ⇧ skipped the relaunch.
        case appStart = "app.start"
        /// The app is quitting. `cause` (`StopReason`), `seconds` the session length, `count` the threads hung up.
        case appStop = "app.stop"
        /// A `Problem` reached the problem list. `severity`, `name` the call site, `template` the literal text of
        /// the title, `cause` (`ProblemCause`), `outcome` `toast` when it was also put on screen.
        case problem
        /// The auto-relaunch at startup. `count` threads started again, `cause` `off` / `shift` when it did not run.
        case threadsRelaunch = "threads.relaunch"
        /// A relaunched agent was asked to go on with the turn the restart cut short.
        case turnResume = "turn.resume"
        /// A turn closed without its `Stop` hook: Scope saw an answer after the turn and settled it to done. `cause`
        /// says who noticed (`island`, `control`, `schedule`). This is the lost-hook signal.
        case turnSettled = "turn.settled"
        /// A turn that did not end on its own. `cause` `esc`, `sent` (a message typed in mid-turn), `exit` (the
        /// process went away), `restart` (Scope quit with it open) or `unknown`.
        case turnInterrupted = "turn.interrupted"
        /// A permission `claude agents` had confirmed early was decided by another hook.
        case permissionDecidedElsewhere = "permission.decided-elsewhere"
        /// A hook message dropped on arrival. `cause` (`HookDropCause`).
        case hookDropped = "hook.dropped"
        /// A CLI or MCP request. `name` the method, `outcome` `ok` / `refused` / `error`, `cause` the refusal rule or
        /// the error code, `source` `agent` / `user`, `client` `cli` / `mcp` / `other`, `seconds` how long it took.
        case control
        /// Task operations: `outcome` `ok` / `failed` / `cancelled`, `seconds`, `count` repositories or items.
        case taskCreate = "task.create"
        case taskSetup = "task.setup"
        case taskArchive = "task.archive"
        case taskClose = "task.close"
        /// One garbage-collection pass. `count` what it removed or stopped.
        case taskGC = "task.gc"
        /// A `gh` call. `name` its first two words (`pr.list`), `outcome` `ok` / `failed` / `auth` / `timeout`.
        case gh
        /// Events of `name`'s kind dropped past the daily cap; `count` how many.
        case journalDropped = "journal.dropped"
    }

    public var at: Date
    public var kind: Kind
    public private(set) var name: String?
    public private(set) var template: String?
    public private(set) var outcome: String?
    public private(set) var cause: String?
    public private(set) var severity: String?
    public private(set) var scope: String?
    public private(set) var task: String?
    public private(set) var thread: String?
    public private(set) var source: String?
    public private(set) var client: String?
    public private(set) var version: String?
    public private(set) var previous: String?
    public private(set) var seconds: Double?
    public private(set) var count: Int?

    public init(at: Date = .now, kind: Kind, name: String? = nil, title: ProblemTitle? = nil, outcome: String? = nil,
                cause: String? = nil, severity: String? = nil, scope: String? = nil, task: String? = nil,
                thread: String? = nil, source: String? = nil, client: String? = nil, version: String? = nil,
                previous: String? = nil, seconds: Double? = nil, count: Int? = nil) {
        self.at = at
        self.kind = kind
        self.name = name.map(Self.token)
        // Only the literal words of a title: a rendered one (`verbatim`) has no template and leaves nothing.
        self.template = title?.template.map(Self.literal)
        self.outcome = outcome.map(Self.token)
        self.cause = cause.map(Self.token)
        self.severity = severity.map(Self.token)
        self.scope = scope.map(Self.token)
        self.task = task.map(Self.token)
        self.thread = thread.map(Self.token)
        self.source = source.map(Self.token)
        self.client = client.map(Self.token)
        self.version = version.map(Self.token)
        self.previous = previous.map(Self.token)
        // Milliseconds are plenty, and a short number keeps the line short.
        self.seconds = seconds.map { ($0 * 1000).rounded() / 1000 }
        self.count = count
    }

    // MARK: Privacy

    /// The placeholder for a value that is not an identifier.
    public static let redacted = "redacted"
    static let tokenLimit = 64
    static let templateLimit = 120

    /// `value` when it reads as an identifier — lowercase letters, digits and `. _ : + -`, no longer than 64 — else
    /// `redacted`. Paths (`/`), sentences (spaces), quotes, anything long and most tokens (mixed case) never make it
    /// through.
    public static func token(_ value: String) -> String {
        guard !value.isEmpty, value.count <= tokenLimit,
              value.unicodeScalars.allSatisfy({ allowedToken.contains($0) }) else { return redacted }
        return value
    }

    private static let allowedToken = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._:+-_")

    /// A title template: text written in the code, placeholders as `{}`. Still refused when it looks like it carries
    /// a path or runs long, in case a caller handed a rendered title instead.
    static func literal(_ value: String) -> String {
        guard !value.isEmpty, value.count <= templateLimit, !value.contains("/"), !value.contains("~"),
              !value.contains("\n") else { return redacted }
        return value
    }

    // MARK: Lines

    /// The UTC day of `at`, `2026-10-27`: what the daily summary groups by.
    public var day: String { Self.day(of: at) }

    public static func day(of date: Date) -> String {
        let parts = JournalLog.utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One line of the journal, without its newline. Keys sorted, dates in ISO 8601.
    public func line() throws -> Data {
        try UsageEvent.encoder.encode(self)
    }

    public static func decode(line: some DataProtocol) -> JournalEvent? {
        try? UsageEvent.decoder.decode(JournalEvent.self, from: Data(line))
    }
}

// MARK: Closed vocabularies

/// How the previous session ended, as the next launch reads it from the session marker.
public enum SessionEnd: String, Codable, Sendable, CaseIterable {
    /// No marker: the first launch with a journal, or a fresh home.
    case first
    /// Quit through `applicationShouldTerminate`.
    case clean
    /// Quit to install an update (Sparkle's install-now).
    case update
    /// The marker was never closed: a crash, a Force Quit, `kill -9` or a power loss — the app cannot tell which.
    case unclean
}

/// Why the app is stopping.
public enum StopReason: String, Codable, Sendable, CaseIterable {
    case quit
    /// Sparkle's install-now: the app quits to be replaced and relaunched.
    case update
    /// The Mac is shutting down, restarting or logging out.
    case powerOff = "power-off"
}

/// Why a hook message was dropped on arrival.
public enum HookDropCause: String, Codable, Sendable, CaseIterable {
    case undecodable
    case malformedThread = "malformed-thread"
    case unknownThread = "unknown-thread"
    case oversized
    case badFrame = "bad-frame"
}

/// A coarse cause read from a problem's detail, so problems count by what went wrong rather than by wording. The
/// detail itself is never kept.
public enum ProblemCause: String, Codable, Sendable, CaseIterable {
    /// 401/403, a login asked for, a token refused.
    case auth
    /// DNS, refused connection, unreachable host, TLS.
    case network
    /// A Node `engines` constraint, `EBADENGINE`.
    case engines
    /// `command not found`, exit 127.
    case notFound = "not-found"
    case permission
    case diskFull = "disk-full"
    case timeout
    /// A git conflict, or a lock file left behind.
    case conflict
    /// A command exited non-zero for another reason.
    case exit
    case unknown

    /// The first cause `detail` matches, checked from the most specific; `unknown` without a detail.
    public static func classify(_ detail: String?) -> ProblemCause {
        guard let text = detail?.lowercased(), !text.isEmpty else { return .unknown }
        let rules: [(ProblemCause, [String])] = [
            (.engines, ["ebadengine", "unsupported engine", "\"engines\"", "engine \"node\""]),
            (.auth, [" 401", "401 unauthorized", " 403", "unauthorized", "authentication", "gh auth login",
                     "not logged in", "permission denied (publickey)", "could not read username", "bad credentials"]),
            (.network, ["could not resolve host", "connection refused", "network is unreachable", "timed out connecting",
                        "enotfound", "econnreset", "econnrefused", "ssl", "tls handshake"]),
            (.diskFull, ["no space left", "enospc", "disk full"]),
            (.notFound, ["command not found", "exit 127", "no such file or directory", "enoent", "not found in path"]),
            (.permission, ["permission denied", "eacces", "operation not permitted"]),
            (.timeout, ["timed out", "timeout"]),
            (.conflict, ["conflict", "index.lock", "unable to create", "already exists"]),
            (.exit, ["exit code", "exited with", "failed: exit", "exit status", "returned non-zero"]),
        ]
        for (cause, needles) in rules where needles.contains(where: text.contains) { return cause }
        return .unknown
    }
}
