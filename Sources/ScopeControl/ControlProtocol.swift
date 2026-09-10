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
    case taskNew = "task.new"

    /// `false` for the calls that only read. Mutating calls go through `AutomationPolicy`.
    public var isMutating: Bool {
        switch self {
        case .ping, .list: false
        case .threadNew, .taskNew: true
        }
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
        /// Refused on purpose: automation off, depth ceiling reached, human said no.
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

/// What the client says about itself. Identity, not authority: the app derives the depth ceiling from its
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
    case taskNew(TaskNewParams)

    public var method: ControlMethod {
        switch self {
        case .ping: .ping
        case .list: .list
        case .threadNew: .threadNew
        case .taskNew: .taskNew
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
        case .list: .seconds(15)
        case .threadNew: .seconds(60)
        case .taskNew: .seconds(300)
        }
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

    public init(prompt: String, scope: String? = nil, repos: [String] = [], branch: String? = nil,
                title: String? = nil, slug: String? = nil, driver: String? = nil,
                dryRun: Bool = false, openThread: Bool = true) {
        self.prompt = prompt
        self.scope = scope
        self.repos = repos
        self.branch = branch
        self.title = title
        self.slug = slug
        self.driver = driver
        self.dryRun = dryRun
        self.openThread = openThread
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

    public init(id: String, title: String, driver: String, scope: String, scopeSlug: String, task: String?,
                cwd: String, state: String, alive: Bool, openedBy: String, depth: Int) {
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

    public init(id: String, name: String, slug: String, branch: String, scope: String, scopeSlug: String,
                root: String, repos: [String], threads: [String]) {
        self.id = id
        self.name = name
        self.slug = slug
        self.branch = branch
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.root = root
        self.repos = repos
        self.threads = threads
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

    public init(created: Bool, task: String? = nil, name: String, slug: String, branch: String,
                scope: String, scopeSlug: String, root: String? = nil, repos: [TaskRepoResult] = [],
                thread: String? = nil) {
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
    }
}

/// A successful answer, typed per method.
public enum ControlResultPayload: Sendable, Equatable {
    case ping(PingResult)
    case list(ListResult)
    case thread(ThreadNewResult)
    case task(TaskNewResult)

    public var method: ControlMethod {
        switch self {
        case .ping: .ping
        case .list: .list
        case .thread: .threadNew
        case .task: .taskNew
        }
    }
}
