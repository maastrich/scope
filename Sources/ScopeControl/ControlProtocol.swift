import Foundation
import ScopeAdapters
import ScopeCore

/// The request/response protocol spoken on the Scope socket by the `scope` CLI and the MCP server.
///
/// One exchange per connection: the client writes a `SocketFrame` holding one line of JSON, then reads
/// reply lines until end-of-file. The last line is always a `result`; `pending` lines before it say what the
/// app is waiting for (a human clicking *Create*, for instance).
///
/// ```
/// → scope-rpc/1
/// → {"caller":{"client":"scope-cli/0.3.1"},"id":"7f2a","method":"thread.new","params":{"scope":"acme"},"rpc":1}
/// ← {"id":"7f2a","kind":"result","ok":true,"result":{"thread":"3f9a2c17be04",…},"rpc":1}
/// ```
///
/// Everything here is pure and lives in the package: the app only implements `ControlService`, the CLI only
/// renders what comes back. Two façades, one protocol, no second implementation.
public enum ControlProtocol {
    /// Payload version. Bumped when a request the previous version could not understand becomes possible;
    /// a server answering `unsupported` is what an older client sees.
    public static let version = 1

    /// Compact, sorted-key JSON: a request is one line, and a reply line never contains a raw newline.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Methods

/// Every call the app answers. The wire carries the raw value; an unknown one is `unsupported`, never a
/// decoding failure, so a `scope` binary installed on the PATH survives the app moving on without it.
public enum ControlMethod: String, Codable, Sendable, CaseIterable {
    case ping
    case list
    case threadNew = "thread.new"
    case threadStop = "thread.stop"
    case threadClose = "thread.close"
    case threadSend = "thread.send"
    case taskNew = "task.new"
    case taskClose = "task.close"
    /// Archive a task: its threads and processes stopped, its worktrees removed, branch and record kept.
    case taskArchive = "task.archive"
    /// File a task under a topic, or out of any: the sidebar regroups, nothing else about the task moves.
    case taskTopic = "task.topic"
    /// Bring an archived task back: its sandboxes rebuilt on its branches, the uncommitted work saved at archive put back.
    case taskRestore = "task.restore"
    /// One pass of the cleanup Scope runs on its own (`TaskManager.collectGarbage`).
    case gc
    /// The last lines of a thread's terminal, scrollback included — or the agent's last answer.
    case threadRead = "thread.read"
    /// Blocks until threads finish their turn (or need someone), then says how each one stands.
    case threadWait = "thread.wait"
    /// What was done over a period, scope by scope, from the records and the history of closed ones.
    case summary
    /// The preferences `ConfigKey` lists, as the app holds them right now.
    case configGet = "config.get"
    /// Changes one of them live, as the Settings window would. The user's own terminal only.
    case configSet = "config.set"
    /// How the user has been using Scope's own interface, from the local usage log.
    case usage

    /// `false` for the calls that only read.
    public var isMutating: Bool {
        switch self {
        case .ping, .list, .threadRead, .threadWait, .summary, .configGet, .usage: false
        case .threadNew, .threadStop, .threadClose, .threadSend, .taskNew, .taskClose, .taskArchive, .taskTopic, .taskRestore, .gc,
             .configSet: true
        }
    }

    /// Whether `AutomationPolicy` has a say. Every mutating call, and reading a thread: another agent's terminal
    /// holds what its user typed and what its tools printed, so it is gated exactly like typing into it. Waiting
    /// answers with the same replies a read does.
    public var isGated: Bool {
        isMutating || self == .threadRead || self == .threadWait
    }
}

// MARK: - Errors

/// A refusal, in the shape the client renders. Never a Swift error crossing the socket.
public struct ControlError: Codable, Sendable, Equatable, Error {
    /// Coarse enough that a client can branch on it, stable enough to keep. Unknown values decode to
    /// `.failed` so a newer app never breaks an older client.
    public enum Code: String, Codable, Sendable {
        /// Malformed request, unusable parameters.
        case badRequest = "bad_request"
        /// Method or protocol version this app does not know.
        case unsupported
        /// Refused on purpose: automation off, a budget or the depth limit reached, human said no.
        case denied
        /// Scope, driver, task or thread does not exist.
        case notFound = "not_found"
        /// The app could not do it (git failure, sandbox missing, …).
        case failed
        /// Nobody answered in time.
        case timeout

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: raw) ?? .failed
        }
    }

    public var code: Code
    public var message: String
    /// Longer text: the git error, the list of scopes to choose from, …
    public var detail: String?

    public init(_ code: Code, _ message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public static func badRequest(_ message: String, detail: String? = nil) -> ControlError { .init(.badRequest, message, detail: detail) }
    public static func notFound(_ message: String, detail: String? = nil) -> ControlError { .init(.notFound, message, detail: detail) }
    public static func denied(_ message: String, detail: String? = nil) -> ControlError { .init(.denied, message, detail: detail) }
    public static func failed(_ message: String, detail: String? = nil) -> ControlError { .init(.failed, message, detail: detail) }
}

extension ControlError: CustomStringConvertible, LocalizedError {
    public var description: String { detail.map { "\(message)\n\($0)" } ?? message }
    public var errorDescription: String? { description }
}

// MARK: - Caller

/// What the client says about itself. Identity, not authority: the app derives depth and lineage from its
/// own records (see `AutomationPolicy`), because everything running under the user's account can write
/// anything here.
public struct ControlCaller: Codable, Sendable, Equatable {
    /// `SCOPE_THREAD` — set for a call made from inside a thread, absent from a plain terminal.
    public var thread: String?
    /// `SCOPE_TASK` when the caller runs in a task sandbox.
    public var task: String?
    /// Working directory of the client, used to guess the scope when none is named.
    public var cwd: String?
    /// `scope-cli/0.3.1`, `scope-mcp/0.3.1`.
    public var client: String

    public init(thread: String? = nil, task: String? = nil, cwd: String? = nil, client: String) {
        self.thread = thread
        self.task = task
        self.cwd = cwd
        self.client = client
    }

    /// The caller a process describes by looking at its own environment.
    public static func fromEnvironment(_ environment: [String: String], cwd: String?, client: String) -> ControlCaller {
        ControlCaller(
            thread: environment["SCOPE_THREAD"].flatMap { $0.isEmpty ? nil : $0 },
            task: environment["SCOPE_TASK"].flatMap { $0.isEmpty ? nil : $0 },
            cwd: cwd,
            client: client
        )
    }
}

// MARK: - Calls

/// One call with its parameters.
public enum ControlCall: Sendable, Equatable {
    case ping
    case list(ListParams)
    case threadNew(ThreadNewParams)
    case threadStop(ThreadTargetParams)
    case threadClose(ThreadTargetParams)
    case threadSend(ThreadSendParams)
    case taskNew(TaskNewParams)
    case taskClose(TaskCloseParams)
    case taskArchive(TaskArchiveParams)
    case taskTopic(TaskTopicParams)
    case taskRestore(TaskRestoreParams)
    case gc(GCParams)
    case threadRead(ThreadReadParams)
    case threadWait(ThreadWaitParams)
    case summary(SummaryParams)
    case configGet(ConfigGetParams)
    case configSet(ConfigSetParams)
    case usage(UsageParams)

    public var method: ControlMethod {
        switch self {
        case .ping: .ping
        case .list: .list
        case .threadNew: .threadNew
        case .threadStop: .threadStop
        case .threadClose: .threadClose
        case .threadSend: .threadSend
        case .taskNew: .taskNew
        case .taskClose: .taskClose
        case .taskArchive: .taskArchive
        case .taskTopic: .taskTopic
        case .taskRestore: .taskRestore
        case .gc: .gc
        case .threadRead: .threadRead
        case .threadWait: .threadWait
        case .summary: .summary
        case .configGet: .configGet
        case .configSet: .configSet
        case .usage: .usage
        }
    }

    /// How long a client waits for this call.
    ///
    /// A read has no reason to take long, and a short bound is what turns "an older Scope is listening and
    /// will never answer a framed request" into an error the user reads instead of a hang. Creating a task
    /// gets the long one: it may be waiting for a human to approve it.
    public var timeout: Duration {
        switch self {
        case .ping: .seconds(5)
        case .list, .threadRead, .summary, .configGet, .configSet, .usage: .seconds(15)
        case .threadNew: .seconds(60)
        case .threadStop, .threadClose, .threadSend, .taskTopic: .seconds(30)
        case .taskNew, .taskClose, .taskArchive, .taskRestore, .gc: .seconds(300)
        // The app answers at the wait's own deadline; the margin covers the reply on the way back.
        case .threadWait(let params): .seconds(params.effectiveTimeout + 15)
        }
    }

    /// How long the app lets the exchange run before answering `timeout` itself: its usual `floor`, except for a
    /// wait, whose length the caller chose — between the app's own deadline and the client's.
    public func serverDeadline(floor: Duration) -> Duration {
        switch self {
        case .threadWait(let params): max(floor, .seconds(params.effectiveTimeout + 10))
        default: floor
        }
    }
}

/// `scope config get [key]` — one preference, or every one `ConfigKey` lists.
public struct ConfigGetParams: Codable, Sendable, Equatable {
    public var key: String?

    public init(key: String? = nil) {
        self.key = key
    }
}

/// `scope config set <key> <value>`.
public struct ConfigSetParams: Codable, Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// `scope thread stop|close <id>` — the thread to act on.
public struct ThreadTargetParams: Codable, Sendable, Equatable {
    /// The thread id (12 hex characters, as `scope list threads` shows it).
    public var thread: String

    public init(thread: String) {
        self.thread = thread
    }
}

/// `scope thread send <id> <text>` — typed into the thread's terminal as if at its keyboard.
public struct ThreadSendParams: Codable, Sendable, Equatable {
    public var thread: String
    public var text: String
    /// Presses ↩ after the text (the default); `false` leaves it on the line.
    public var submit: Bool

    public init(thread: String, text: String, submit: Bool = true) {
        self.thread = thread
        self.text = text
        self.submit = submit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(String.self, forKey: .thread)
        text = try container.decode(String.self, forKey: .text)
        submit = try container.decodeIfPresent(Bool.self, forKey: .submit) ?? true
    }
}

/// `scope thread read <id>` — what the thread's terminal shows, and what scrolled off it.
public struct ThreadReadParams: Codable, Sendable, Equatable {
    /// What to read.
    public enum View: String, Codable, Sendable, CaseIterable {
        /// The terminal: scrollback and screen, paged by line.
        case terminal
        /// The agent's last answer, as its driver reported it at the end of the turn — what "what did it say?"
        /// means, without the spinners and redraws of a TUI. The terminal when the driver reports none.
        case reply
    }

    public var thread: String
    /// How many lines; `ThreadTranscript.defaultLines` when absent, never more than `ThreadTranscript.maxLines`.
    public var lines: Int?
    /// Read up to this absolute line — the `olderCursor` of the previous read; the end when absent.
    public var cursor: Int?
    /// `nil` is the terminal: what an older client meant by a read.
    public var view: View?

    public init(thread: String, lines: Int? = nil, cursor: Int? = nil, view: View? = nil) {
        self.thread = thread
        self.lines = lines
        self.cursor = cursor
        self.view = view
    }
}

/// `scope thread wait <id>…` — returns once the threads are done with their turn, so a caller follows the agents it
/// started without polling their terminals.
public struct ThreadWaitParams: Codable, Sendable, Equatable {
    public enum Until: String, Codable, Sendable, CaseIterable {
        /// Every thread settled.
        case all
        /// The first one to settle.
        case any
    }

    public static let defaultTimeout = 600
    public static let maxTimeout = 3600

    public var threads: [String]
    public var until: Until
    /// Seconds; the answer then says which threads are still at work. `defaultTimeout` when absent.
    public var timeout: Int?

    public init(threads: [String], until: Until = .all, timeout: Int? = nil) {
        self.threads = threads
        self.until = until
        self.timeout = timeout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threads = try container.decode([String].self, forKey: .threads)
        // An empty `any` wait would sleep to its deadline for nothing.
        guard !threads.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .threads, in: container, debugDescription: "no thread to wait for")
        }
        until = try container.decodeIfPresent(Until.self, forKey: .until) ?? .all
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
    }

    /// `timeout` clamped to `1...maxTimeout`.
    public var effectiveTimeout: Int {
        min(max(timeout ?? Self.defaultTimeout, 1), Self.maxTimeout)
    }
}

/// `scope task archive <id|slug>` — threads and processes stopped, worktrees removed, uncommitted work saved;
/// the branch and the record stay.
public struct TaskArchiveParams: Codable, Sendable, Equatable {
    /// Task id or slug.
    public var task: String

    public init(task: String) {
        self.task = task
    }
}

/// `scope task restore <id|slug>` — an archived task back where it was: worktrees on its branches, the uncommitted
/// changes saved at archive restored into them.
public struct TaskRestoreParams: Codable, Sendable, Equatable {
    /// Task id or slug, of an archived task.
    public var task: String
    /// Slug, name, id or path of the task's scope, when the slug exists in several.
    public var scope: String?

    public init(task: String, scope: String? = nil) {
        self.task = task
        self.scope = scope
    }
}

/// `scope task topic [<id|slug>] <topic>` / `--clear` — the label only: branch, worktrees and threads stay as they are.
public struct TaskTopicParams: Codable, Sendable, Equatable {
    /// Task id or slug; `nil` = the task the caller's thread runs in.
    public var task: String?
    /// The topic to file it under; `nil` takes it out of any. The façades insist on saying which: an empty topic is
    /// refused there rather than read as a clear.
    public var topic: String?
    /// Whether the tasks it started, and theirs, follow it when they still share its old topic.
    public var children: Bool

    public init(task: String? = nil, topic: String?, children: Bool = true) {
        self.task = task
        self.topic = topic
        self.children = children
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        children = try container.decodeIfPresent(Bool.self, forKey: .children) ?? true
    }
}

/// `scope gc` — what Scope cleans on its own, now.
public struct GCParams: Codable, Sendable, Equatable {
    /// Say what would go, touch nothing.
    public var dryRun: Bool

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }
}

/// `scope task close <id|slug>` — the undo of a task: its threads hung up, its worktrees removed.
public struct TaskCloseParams: Codable, Sendable, Equatable {
    /// Task id or slug.
    public var task: String
    /// Deletes the task's branch too; an unmerged one's last commit is kept under `refs/scope/salvage/`.
    public var deleteBranch: Bool
    /// Ignored, kept so an older client's request still decodes: a close no longer refuses anything, it saves
    /// uncommitted work and unmerged branches before removing them.
    public var force: Bool

    public init(task: String, deleteBranch: Bool = false, force: Bool = false) {
        self.task = task
        self.deleteBranch = deleteBranch
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(String.self, forKey: .task)
        deleteBranch = try container.decodeIfPresent(Bool.self, forKey: .deleteBranch) ?? false
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

/// `scope list` — what to show.
public struct ListParams: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case all, scopes, threads, tasks
    }

    public var kind: Kind
    /// Slug, name, id or path of one scope; `nil` for every scope.
    public var scope: String?

    public init(kind: Kind = .all, scope: String? = nil) {
        self.kind = kind
        self.scope = scope
    }
}

/// `scope thread new`.
public struct ThreadNewParams: Codable, Sendable, Equatable {
    /// Slug, name, id or path. `nil` = the caller's own scope, then the scope containing its cwd.
    public var scope: String?
    /// Driver profile id; `nil` = the scope's usual one.
    public var driver: String?
    /// Task id or slug: opens the thread in that task's sandbox instead of the scope root.
    public var task: String?
    /// Repository, relative to the scope root: opens the thread there.
    public var repo: String?
    /// Row label; `nil` = what the app would have named it.
    public var title: String?
    /// First thing typed into the driver once it is up.
    public var prompt: String?

    public init(scope: String? = nil, driver: String? = nil, task: String? = nil, repo: String? = nil,
                title: String? = nil, prompt: String? = nil) {
        self.scope = scope
        self.driver = driver
        self.task = task
        self.repo = repo
        self.title = title
        self.prompt = prompt
    }
}

/// `scope task new` — a task is a branch and one worktree per repository, so it says what it will do
/// before it does it (`dryRun`) and the app can still ask the user.
public struct TaskNewParams: Codable, Sendable, Equatable {
    /// What the task is about; also the driver's opening request.
    public var prompt: String
    public var scope: String?
    /// Repositories relative to the scope root; empty = let the app propose them.
    public var repos: [String]
    /// Branch name; `nil` = proposed from the prompt (the headless proposal path).
    public var branch: String?
    /// Task title; `nil` = proposed.
    public var title: String?
    /// Sandbox folder name; `nil` = derived from the title.
    public var slug: String?
    public var driver: String?
    /// Answer with the proposal and create nothing.
    public var dryRun: Bool
    /// Open the task's first thread once it exists (the app's own behaviour). `false` leaves it cold.
    public var openThread: Bool
    /// Run the repositories' setup commands in the new sandboxes before the first thread starts (the default).
    /// `false` still copies the `.env*` files.
    public var runSetup: Bool
    /// The topic the task is filed under in the sidebar; `nil` = the topic of the caller's own task, if any.
    public var topic: String?
    /// The pull request to start from (`#123`, `owner/repo#123`, a URL, `123`): its head is checked out instead of
    /// a new branch. Given, it must resolve or the call fails; `nil` = only a pull request the prompt asks to work
    /// on (`PullRequestReference.startPoint`), and one that does not resolve is ignored.
    public var startPR: String?

    public init(prompt: String, scope: String? = nil, repos: [String] = [], branch: String? = nil,
                title: String? = nil, slug: String? = nil, driver: String? = nil,
                dryRun: Bool = false, openThread: Bool = true, runSetup: Bool = true, topic: String? = nil,
                startPR: String? = nil) {
        self.prompt = prompt
        self.scope = scope
        self.repos = repos
        self.branch = branch
        self.title = title
        self.slug = slug
        self.driver = driver
        self.dryRun = dryRun
        self.openThread = openThread
        self.runSetup = runSetup
        self.topic = topic
        self.startPR = startPR
    }

    // Lenient on everything but the prompt: a `scope` binary older than a field never sends it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        repos = try container.decodeIfPresent([String].self, forKey: .repos) ?? []
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        openThread = try container.decodeIfPresent(Bool.self, forKey: .openThread) ?? true
        runSetup = try container.decodeIfPresent(Bool.self, forKey: .runSetup) ?? true
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        startPR = try container.decodeIfPresent(String.self, forKey: .startPR)
    }
}

// MARK: - Results

/// `ping` — enough for a client to know what it is talking to and what it may ask for.
public struct PingResult: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var home: String
    public var rpc: Int
    /// Raw values of `ControlMethod`, so a client can hide what this app cannot do.
    public var methods: [String]
    /// What automation is allowed right now (`AutomationSettings`), for `scope doctor` and the MCP banner.
    public var automation: AutomationSettings

    public init(app: String, version: String, home: String, rpc: Int = ControlProtocol.version,
                methods: [String] = ControlMethod.allCases.map(\.rawValue), automation: AutomationSettings) {
        self.app = app
        self.version = version
        self.home = home
        self.rpc = rpc
        self.methods = methods
        self.automation = automation
    }
}

public struct ScopeSummary: Codable, Sendable, Equatable {
    public var id: String
    public var slug: String
    public var name: String
    public var path: String
    /// `ok`, `missing`, … — the app's own word for the scope's state.
    public var status: String
    /// Repository paths relative to the scope root.
    public var repos: [String]

    public init(id: String, slug: String, name: String, path: String, status: String, repos: [String]) {
        self.id = id
        self.slug = slug
        self.name = name
        self.path = path
        self.status = status
        self.repos = repos
    }
}

public struct ThreadSummary: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var driver: String
    public var scope: String
    public var scopeSlug: String
    public var task: String?
    public var cwd: String
    /// `idle`, `working`, `needsInput`, `exited`, …
    public var state: String
    public var alive: Bool
    /// How the thread was opened: `user`, or the client that asked for it.
    public var openedBy: String
    /// 0 for a thread a human opened, +1 for each generation of agent below it.
    public var depth: Int
    /// The thread whose agent opened this one, when one did: the one to answer.
    public var parent: String?
    /// `orchestrator` or `terminal` for the two threads Scope keeps in every scope, which can be stopped but not
    /// closed; absent for the others. The orchestrator is the agent that drives its scope.
    public var resident: String?
    /// The latest thing its agent did, and when (`ThreadActivityLine`): `Edit Sources/App.swift · 2m ago`. Absent
    /// until its driver reports something, and for good without an adapter.
    public var activity: String?
    /// Tokens its agent consumed over the last five hours (`TokenUsageText.threadField`): `1.2M · 5h`. Absent for a
    /// thread Scope reads no Claude Code transcript for.
    public var tokens: String?

    public init(id: String, title: String, driver: String, scope: String, scopeSlug: String, task: String?,
                cwd: String, state: String, alive: Bool, openedBy: String, depth: Int, parent: String? = nil,
                resident: String? = nil, activity: String? = nil, tokens: String? = nil) {
        self.id = id
        self.title = title
        self.driver = driver
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.task = task
        self.cwd = cwd
        self.state = state
        self.alive = alive
        self.openedBy = openedBy
        self.depth = depth
        self.parent = parent
        self.resident = resident
        self.activity = activity
        self.tokens = tokens
    }
}

public struct TaskSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var slug: String
    public var branch: String
    public var scope: String
    public var scopeSlug: String
    public var root: String
    public var repos: [String]
    public var threads: [String]
    /// The topic the task is filed under, if any.
    public var topic: String?
    /// The task whose agent created this one, if any.
    public var parentTask: String?
    /// When it was archived; `nil` for a live task. An archived task has no sandbox until `task.restore` brings it back.
    public var archivedAt: Date?

    public init(id: String, name: String, slug: String, branch: String, scope: String, scopeSlug: String,
                root: String, repos: [String], threads: [String], topic: String? = nil, parentTask: String? = nil,
                archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.branch = branch
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.root = root
        self.repos = repos
        self.threads = threads
        self.topic = topic
        self.parentTask = parentTask
        self.archivedAt = archivedAt
    }
}

public struct ListResult: Codable, Sendable, Equatable {
    public var scopes: [ScopeSummary]
    public var threads: [ThreadSummary]
    public var tasks: [TaskSummary]

    public init(scopes: [ScopeSummary] = [], threads: [ThreadSummary] = [], tasks: [TaskSummary] = []) {
        self.scopes = scopes
        self.threads = threads
        self.tasks = tasks
    }
}

public struct ThreadNewResult: Codable, Sendable, Equatable {
    public var thread: String
    public var title: String
    public var driver: String
    public var scope: String
    public var scopeSlug: String
    public var cwd: String
    public var task: String?
    public var depth: Int

    public init(thread: String, title: String, driver: String, scope: String, scopeSlug: String,
                cwd: String, task: String? = nil, depth: Int) {
        self.thread = thread
        self.title = title
        self.driver = driver
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.cwd = cwd
        self.task = task
        self.depth = depth
    }
}

/// One repository a task sandboxed: where its worktree is and what happened to its branch.
public struct TaskRepoResult: Codable, Sendable, Equatable {
    public var repo: String
    public var worktree: String
    public var branch: String
    /// `true` when the branch did not exist and the task created it — what an undo would delete.
    public var branchCreated: Bool

    public init(repo: String, worktree: String, branch: String, branchCreated: Bool) {
        self.repo = repo
        self.worktree = worktree
        self.branch = branch
        self.branchCreated = branchCreated
    }
}

public struct TaskNewResult: Codable, Sendable, Equatable {
    /// `false` for a `dryRun`: everything below is what *would* be created.
    public var created: Bool
    public var task: String?
    public var name: String
    public var slug: String
    public var branch: String
    public var scope: String
    public var scopeSlug: String
    public var root: String?
    public var repos: [TaskRepoResult]
    /// The thread opened in the new task, when one was.
    public var thread: String?
    /// The topic the task is filed under: the one asked for, or the one it inherited from the caller's task.
    public var topic: String?
    /// One line about something Scope decided on the caller's behalf (a pull request it ignored), when it did.
    public var note: String?

    public init(created: Bool, task: String? = nil, name: String, slug: String, branch: String,
                scope: String, scopeSlug: String, root: String? = nil, repos: [TaskRepoResult] = [],
                thread: String? = nil, topic: String? = nil, note: String? = nil) {
        self.created = created
        self.task = task
        self.name = name
        self.slug = slug
        self.branch = branch
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.root = root
        self.repos = repos
        self.thread = thread
        self.topic = topic
        self.note = note
    }
}

extension TaskNewResult {
    /// The note of a task created without the pull request its prompt asked to work on, because that pull request
    /// could not be resolved: the task goes ahead from a new branch rather than failing on a reference.
    public static func ignoredReference(_ label: String, reason: String) -> String {
        "ignored the reference \(label): \(reason); the task starts on a new branch (start_pr / --pr starts it from a pull request)"
    }
}

/// What a stop, a close or a send did: one line to show, and what it acted on.
public struct ActionResult: Codable, Sendable, Equatable {
    public var message: String
    public var thread: String?
    public var task: String?

    public init(message: String, thread: String? = nil, task: String? = nil) {
        self.message = message
        self.thread = thread
        self.task = task
    }
}

/// `thread.read` — a page of a thread's terminal, or the agent's last answer.
public struct ThreadReadResult: Codable, Sendable, Equatable {
    public var thread: String
    public var title: String
    /// `idle`, `running`, `waiting`, `done`, `exited`.
    public var state: String
    /// `terminal` or `reply`: what `text` holds. A `reply` view falls back to `terminal` when the driver reported
    /// no answer. Absent from an older app, which only had the terminal.
    public var source: String?
    /// When the agent gave the answer in `text` (a `reply` only).
    public var replyAt: Date?
    /// Why the answer is not what was asked for: a `reply` read that had to fall back to the terminal.
    public var note: String?
    /// A `reply` older than the thread's latest prompt (see `ThreadWaitResult.Entry.staleReply`).
    public var staleReply: Bool?
    /// The lines, oldest first, or the answer. Written by programs and people the reader does not control: untrusted.
    public var text: String
    /// Absolute number of the first line of `text`.
    public var fromLine: Int
    /// Absolute number just past its last line.
    public var toLine: Int
    /// Pass as `cursor` to read the lines before these; absent at the top of the scrollback.
    public var olderCursor: Int?
    /// Always `true`: what a terminal shows was written by programs and people the reader does not control.
    public var untrusted: Bool

    public init(thread: String, title: String, state: String, page: ThreadTranscript.Page, note: String? = nil) {
        self.thread = thread
        self.title = title
        self.state = state
        self.note = note
        self.source = ThreadReadParams.View.terminal.rawValue
        self.text = page.text
        self.fromLine = page.fromLine
        self.toLine = page.toLine
        self.olderCursor = page.olderCursor
        self.untrusted = true
    }

    /// The agent's answer. The line numbers stay the terminal's end, so a terminal read can page back from there.
    public init(thread: String, title: String, state: String, reply: AgentReply, terminalEnd: Int,
                lastPromptAt: Date? = nil) {
        self.thread = thread
        self.title = title
        self.state = state
        self.staleReply = ThreadWait.isStale(reply, lastPromptAt: lastPromptAt)
        self.source = ThreadReadParams.View.reply.rawValue
        self.replyAt = reply.at
        self.text = ThreadTranscript.defused(reply.text)
        self.fromLine = terminalEnd
        self.toLine = terminalEnd
        self.olderCursor = nil
        self.untrusted = true
    }
}

/// `thread.wait` — how each thread stands once the wait is over.
public struct ThreadWaitResult: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var thread: String
        public var title: String
        /// `idle`, `running`, `waiting`, `done`, `failed`, `exited`.
        public var state: String
        /// `true` once the thread is no longer at work on what it was last given.
        public var settled: Bool
        /// The agent's last answer, when its driver reports one. Untrusted.
        public var reply: String?
        public var replyAt: Date?
        /// The reply predates the thread's latest prompt: it answers something else, and this turn has not
        /// answered yet (a question, a permission, a deadline came first).
        public var staleReply: Bool?

        public init(thread: String, title: String, state: String, settled: Bool, reply: AgentReply? = nil,
                    lastPromptAt: Date? = nil) {
            self.thread = thread
            self.title = title
            self.state = state
            self.settled = settled
            self.reply = reply.map { ThreadTranscript.defused($0.text) }
            self.replyAt = reply?.at
            self.staleReply = reply.map { ThreadWait.isStale($0, lastPromptAt: lastPromptAt) }
        }
    }

    public var threads: [Entry]
    /// `false` when the deadline came first.
    public var complete: Bool
    /// Seconds spent waiting.
    public var waited: Int
    /// Always `true`: the replies are agents' output.
    public var untrusted: Bool

    public init(threads: [Entry], complete: Bool, waited: Int) {
        self.threads = threads
        self.complete = complete
        self.waited = waited
        self.untrusted = true
    }
}

/// A successful answer, typed per method.
public enum ControlResultPayload: Sendable, Equatable {
    case ping(PingResult)
    case list(ListResult)
    case thread(ThreadNewResult)
    case task(TaskNewResult)
    /// The answer of every call that acts on something existing, with the method it answers.
    case action(ActionResult, ControlMethod)
    case read(ThreadReadResult)
    case wait(ThreadWaitResult)
    case summary(SummaryResult)
    case usage(UsageResult)

    public var method: ControlMethod {
        switch self {
        case .ping: .ping
        case .list: .list
        case .thread: .threadNew
        case .task: .taskNew
        case .action(_, let method): method
        case .read: .threadRead
        case .wait: .threadWait
        case .summary: .summary
        case .usage: .usage
        }
    }
}
