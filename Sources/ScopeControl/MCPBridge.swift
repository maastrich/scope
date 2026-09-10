import Foundation

/// What `scope mcp` exposes, described without a single MCP type.
///
/// The MCP server is a façade over the same `ControlCall` values the CLI builds: it owns no logic, and the
/// tools below are only names, schemas and a mapping. Keeping the descriptions here rather than in the
/// binary means they are testable, and that the two façades cannot drift.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    /// JSON Schema of the arguments, as a JSON object.
    public var schema: String
    /// `true` when the tool only reads.
    public var readOnly: Bool
    /// `true` when the tool writes to the user's repositories (branches, worktrees).
    public var destructive: Bool

    public init(name: String, title: String, description: String, schema: String,
                readOnly: Bool, destructive: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.schema = schema
        self.readOnly = readOnly
        self.destructive = destructive
    }
}

/// The bridge between MCP tool calls and control calls.
public enum MCPBridge {
    /// Name of the MCP server as clients see it.
    public static let serverName = "scope"

    /// What an agent is told about the server as a whole.
    public static let instructions = """
    Scope is the macOS app running the threads and tasks of this machine. A thread is a driver (Claude Code, \
    Codex, a shell) in a terminal; a task is a branch with one git worktree per repository, so work happens \
    in a sandbox rather than in the user's checkout.

    The user runs Scope so agents can work unattended: open threads and create tasks when the work calls for \
    it, without asking them first. Scope refuses recursion past its configured depth and applies whatever \
    approval the user set in its settings — a refusal is an answer, not an error to work around. You may stop, \
    close or type into only the threads you opened; scope_task_close undoes a task.
    """

    public static let tools: [MCPTool] = [
        MCPTool(
            name: "scope_list",
            title: "List scopes, threads and tasks",
            description: """
            What Scope is holding right now: the declared scopes (folders), the running threads and the \
            tasks with their branches and sandboxes. Start here to find the scope slug or task id the other \
            tools need.
            """,
            schema: """
            {"type":"object","properties":{\
            "kind":{"type":"string","enum":["all","scopes","threads","tasks"],"description":"What to list; defaults to all."},\
            "scope":{"type":"string","description":"Slug, name, id or path of one scope; omit for every scope."}\
            },"additionalProperties":false}
            """,
            readOnly: true
        ),
        MCPTool(
            name: "scope_thread_new",
            title: "Open a thread",
            description: """
            Opens a thread in Scope: a driver starts in a terminal in the scope root, a repository of it, or \
            a task's sandbox, and the answer is the new thread's id. Give `prompt` to hand the driver its \
            opening request. Scope refuses this when the chain of agents opening agents would go past the \
            depth the user allowed.
            """,
            schema: """
            {"type":"object","properties":{\
            "scope":{"type":"string","description":"Slug, name, id or path. Defaults to the caller's own scope."},\
            "driver":{"type":"string","description":"Driver profile id (claude-code, codex, shell…). Defaults to the scope's usual one."},\
            "task":{"type":"string","description":"Task id or slug: opens the thread in that task's sandbox."},\
            "repo":{"type":"string","description":"Repository relative to the scope root."},\
            "title":{"type":"string","description":"Row label for the thread."},\
            "prompt":{"type":"string","description":"First request handed to the driver."}\
            },"additionalProperties":false}
            """,
            readOnly: false
        ),
        MCPTool(
            name: "scope_task_new",
            title: "Create a task",
            description: """
            Creates a task: a branch and one git worktree per repository under Scope's sandboxes, then its \
            first thread. The branch name is proposed by the driver from the prompt unless you give one. \
            Call it with dry_run true first — that answers with the title, branch, sandbox and worktrees it \
            would create and writes nothing. The real call may wait for the user to approve it, and a \
            refusal comes back as an error.
            """,
            schema: """
            {"type":"object","properties":{\
            "prompt":{"type":"string","description":"What the task is about; also the first request handed to its driver."},\
            "scope":{"type":"string","description":"Slug, name, id or path. Defaults to the caller's own scope."},\
            "repos":{"type":"array","items":{"type":"string"},"description":"Repositories relative to the scope root; omitted lets Scope work them out from the prompt."},\
            "branch":{"type":"string","description":"Branch to create; omitted lets the driver propose one."},\
            "title":{"type":"string","description":"Task name; omitted lets the driver propose one."},\
            "driver":{"type":"string","description":"Driver for the task's first thread."},\
            "dry_run":{"type":"boolean","description":"Answer with the proposal and create nothing."},\
            "open_thread":{"type":"boolean","description":"Open the task's first thread (default true)."}\
            },"required":["prompt"],"additionalProperties":false}
            """,
            readOnly: false,
            destructive: true
        ),
        MCPTool(
            name: "scope_thread_send",
            title: "Type into a thread",
            description: """
            Types text into a thread's terminal, as if at its keyboard, and presses Return unless submit is false. \
            Only for threads you opened: it is how you hand a follow-up to the agent you started.
            """,
            schema: """
            {"type":"object","properties":{\
            "thread":{"type":"string","description":"Thread id, from scope_thread_new or scope_list."},\
            "text":{"type":"string","description":"What to type."},\
            "submit":{"type":"boolean","description":"Press Return after the text (default true)."}\
            },"required":["thread","text"],"additionalProperties":false}
            """,
            readOnly: false
        ),
        MCPTool(
            name: "scope_thread_stop",
            title: "Stop a thread",
            description: "Stops the process of a thread you opened. Its row stays, so it can be relaunched.",
            schema: #"{"type":"object","properties":{"thread":{"type":"string","description":"Thread id."}},"required":["thread"],"additionalProperties":false}"#,
            readOnly: false
        ),
        MCPTool(
            name: "scope_thread_close",
            title: "Close a thread",
            description: "Hangs up a thread you opened and removes it from Scope.",
            schema: #"{"type":"object","properties":{"thread":{"type":"string","description":"Thread id."}},"required":["thread"],"additionalProperties":false}"#,
            readOnly: false,
            destructive: true
        ),
        MCPTool(
            name: "scope_task_close",
            title: "Close a task",
            description: """
            Undoes a task: hangs up its threads and removes its worktrees; with delete_branch, deletes its branch \
            too. Asks the user first. Refused when there is uncommitted work or an unmerged branch, unless force — \
            which loses it.
            """,
            schema: """
            {"type":"object","properties":{\
            "task":{"type":"string","description":"Task id or slug."},\
            "delete_branch":{"type":"boolean","description":"Delete the task's branch as well."},\
            "force":{"type":"boolean","description":"Close even with uncommitted changes or an unmerged branch."}\
            },"required":["task"],"additionalProperties":false}
            """,
            readOnly: false,
            destructive: true
        ),
        MCPTool(
            name: "scope_ping",
            title: "Check Scope",
            description: "Whether Scope is listening, its version, and what agents are currently allowed to do.",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            readOnly: true
        ),
    ]

    /// Turns a tool call into a control call. `arguments` is the raw JSON object the client sent.
    public static func call(tool name: String, arguments: Data) -> Result<ControlCall, ControlError> {
        let decoder = ControlProtocol.makeDecoder()
        do {
            switch name {
            case "scope_ping":
                return .success(.ping)
            case "scope_list":
                return .success(.list(try decoder.decode(ListArguments.self, from: arguments).call))
            case "scope_thread_new":
                return .success(.threadNew(try decoder.decode(ThreadNewParams.self, from: arguments)))
            case "scope_task_new":
                return .success(.taskNew(try decoder.decode(TaskNewArguments.self, from: arguments).call))
            case "scope_thread_send":
                return .success(.threadSend(try decoder.decode(ThreadSendParams.self, from: arguments)))
            case "scope_thread_stop":
                return .success(.threadStop(try decoder.decode(ThreadTargetParams.self, from: arguments)))
            case "scope_thread_close":
                return .success(.threadClose(try decoder.decode(ThreadTargetParams.self, from: arguments)))
            case "scope_task_close":
                return .success(.taskClose(try decoder.decode(TaskCloseArguments.self, from: arguments).call))
            default:
                return .failure(.init(.unsupported, "no tool called “\(name)”",
                                      detail: tools.map(\.name).joined(separator: ", ")))
            }
        } catch {
            return .failure(.badRequest("unusable arguments for \(name)", detail: String(describing: error)))
        }
    }

    /// What the agent reads. The same text a person gets from the CLI: one shape to keep right.
    public static func text(for payload: ControlResultPayload) -> String {
        CLIRenderer.text(payload)
    }

    /// The machine-readable half of the answer, for clients that use `structuredContent`.
    public static func structured(for payload: ControlResultPayload) throws -> Data {
        let encoder = ControlProtocol.makeEncoder()
        return switch payload {
        case .ping(let result): try encoder.encode(result)
        case .list(let result): try encoder.encode(result)
        case .thread(let result): try encoder.encode(result)
        case .task(let result): try encoder.encode(result)
        case .action(let result, _): try encoder.encode(result)
        }
    }

    /// `scope_task_close` arguments, snake_case like the other task tool.
    struct TaskCloseArguments: Decodable {
        var task: String
        var deleteBranch: Bool?
        var force: Bool?

        private enum CodingKeys: String, CodingKey {
            case task
            case deleteBranch = "delete_branch"
            case force
        }

        var call: TaskCloseParams {
            TaskCloseParams(task: task, deleteBranch: deleteBranch ?? false, force: force ?? false)
        }
    }

    /// `scope_list` arguments, which differ from `ListParams` only in being lenient about `kind`.
    struct ListArguments: Decodable {
        var kind: String?
        var scope: String?

        var call: ListParams {
            ListParams(kind: kind.flatMap(ListParams.Kind.init(rawValue:)) ?? .all, scope: scope)
        }
    }

    /// `scope_task_new` arguments: snake_case, as JSON Schema and agents prefer.
    struct TaskNewArguments: Decodable {
        var prompt: String
        var scope: String?
        var repos: [String]?
        var branch: String?
        var title: String?
        var slug: String?
        var driver: String?
        var dryRun: Bool?
        var openThread: Bool?

        private enum CodingKeys: String, CodingKey {
            case prompt, scope, repos, branch, title, slug, driver
            case dryRun = "dry_run"
            case openThread = "open_thread"
        }

        var call: TaskNewParams {
            TaskNewParams(prompt: prompt, scope: scope, repos: repos ?? [], branch: branch, title: title,
                          slug: slug, driver: driver, dryRun: dryRun ?? false, openThread: openThread ?? true)
        }
    }
}
