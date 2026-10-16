import Foundation
import ScopeCore

/// Who is asking, as the app resolved it — not as the caller claimed.
///
/// `SCOPE_THREAD` is an environment variable in a process the user owns, so anything under that account can
/// set it to anything. The app therefore looks the id up in its own records and any answer it cannot vouch
/// for lands in `.strangerThread`.
public enum ControlOrigin: Sendable, Equatable {
    /// No `SCOPE_THREAD`: a terminal the user typed in. That is the user, and the user is allowed.
    case user
    /// A thread the app owns, with the depth stored on its record (0 for one the user opened).
    case thread(ThreadID, depth: Int)
    /// A `SCOPE_THREAD` naming no thread this app knows: a closed thread's shell, or someone guessing.
    case strangerThread(String)
    /// `scope mcp` called from outside any Scope thread — a Claude Code, Codex or Cursor session the user started
    /// elsewhere, with the server registered globally. An agent all the same: it gets the rules of one at depth 0.
    case externalAgent(client: String)
}

extension ControlOrigin {
    /// A caller the automation settings govern: a Scope thread or an agent outside Scope.
    public var isAgent: Bool {
        switch self {
        case .thread, .externalAgent: true
        case .user, .strangerThread: false
        }
    }
}

/// What agents keep open right now, every scope together — or what one request would add to it.
///
/// The budgets count this rather than how deep a chain goes: a loop of tasks creating tasks costs a worktree and a
/// process per turn whatever its shape, and one agent fanning out wide fills the disk as surely as a deep chain.
public struct AutomationLoad: Sendable, Equatable {
    /// Tasks an agent created and nobody archived or closed yet.
    public var tasks: Int
    /// Threads an agent opened (a task's first thread included) that are still running.
    public var threads: Int

    public init(tasks: Int = 0, threads: Int = 0) {
        self.tasks = tasks
        self.threads = threads
    }

    public static let zero = AutomationLoad()

    public var isZero: Bool { tasks == 0 && threads == 0 }

    public static func + (lhs: AutomationLoad, rhs: AutomationLoad) -> AutomationLoad {
        AutomationLoad(tasks: lhs.tasks + rhs.tasks, threads: lhs.threads + rhs.threads)
    }

    public static func - (lhs: AutomationLoad, rhs: AutomationLoad) -> AutomationLoad {
        AutomationLoad(tasks: max(0, lhs.tasks - rhs.tasks), threads: max(0, lhs.threads - rhs.threads))
    }
}

/// The share of the budgets held by requests that were allowed and are still being carried out.
///
/// Creating a task awaits a proposal and a worktree for seconds; five calls sent together would otherwise all be
/// measured against a count none of them has raised yet. `ControlDispatch` reserves before the work starts and
/// releases once the work is over, when the app's own count has taken over.
@MainActor
public final class AutomationReservations {
    public private(set) var pending = AutomationLoad.zero

    public init() {}

    public func reserve(_ load: AutomationLoad) { pending = pending + load }
    public func release(_ load: AutomationLoad) { pending = pending - load }
}

/// The names clients give themselves in `ControlCaller.client`, before the `/version`.
public enum ControlClientName {
    /// The `scope` command line — the user typing.
    public static let cli = "scope-cli"
    /// `scope mcp` — an agent speaking MCP.
    public static let mcp = "scope-mcp"
}

/// What to do with a request, before anything happens.
public enum PolicyDecision: Sendable, Equatable {
    /// Go ahead.
    case allow
    /// Ask the user first; `subject` is what the sheet says is being asked for.
    case ask(subject: String)
    /// Refuse, with the answer to send back.
    case refuse(ControlError)
}

/// The rules between a control request and the app doing anything.
///
/// Pure and testable on its own: the app hands it the settings, the resolved origin and what agents keep open, it
/// answers what to do. What it exists for is agents opening agents without anyone watching — any task may create
/// tasks, so the guard is a budget of live agent work (`maxAgentTasks`, `maxAgentThreads`) rather than a depth —
/// and the fact that creating a task writes branches and worktrees into the user's repositories.
public struct AutomationPolicy: Sendable, Equatable {
    public var settings: AutomationSettings

    public init(settings: AutomationSettings) {
        self.settings = settings
    }

    /// The depth a thread opened by `origin` would carry.
    public static func childDepth(of origin: ControlOrigin) -> Int {
        switch origin {
        case .user: 0
        case .thread(_, let depth): depth + 1
        case .strangerThread: 0
        case .externalAgent: 1
        }
    }

    /// Turns what a caller claims into an origin the app can reason about.
    ///
    /// A `SCOPE_THREAD` is checked against the app's own threads (`threadDepth` answers for the ones it runs). No
    /// thread at all means a terminal: the user themselves when it is the command line, an agent when it is
    /// `scope mcp` — registered globally, the MCP server is reached from sessions Scope never launched, and those
    /// must not inherit the free pass the user's own typing gets. The client name is the caller's word, and an
    /// agent with a shell can still run `scope` itself: the socket belongs to the user's account either way.
    public static func origin(of caller: ControlCaller, threadDepth: (ThreadID) -> Int?) -> ControlOrigin {
        if let raw = caller.thread, !raw.isEmpty {
            guard let id = ThreadID(rawValue: raw), let depth = threadDepth(id) else { return .strangerThread(raw) }
            return .thread(id, depth: depth)
        }
        return caller.client.hasPrefix(ControlClientName.mcp + "/") ? .externalAgent(client: caller.client) : .user
    }

    /// What `call` would add to the agents' load if it went ahead. A dry run creates nothing.
    public static func cost(of call: ControlCall) -> AutomationLoad {
        switch call {
        case .threadNew: return AutomationLoad(threads: 1)
        case .taskNew(let params) where !params.dryRun:
            // N attempts are N tasks, each with its own thread: the budget sees them all before any is created.
            let count = max(1, params.attempts)
            return AutomationLoad(tasks: count, threads: params.openThread ? count : 0)
        // An archived task holds no budget; brought back, it holds one again, like a new one.
        case .taskRestore: return AutomationLoad(tasks: 1)
        default: return .zero
        }
    }

    /// The refusal when `count` attempts (`task new --attempts`) would take agents past their task budget, with the
    /// numbers: the caller can only lower N, or archive something, knowing how far off it is.
    public static func attemptsRefusal(count: Int, open: Int, limit: Int) -> String? {
        let left = max(0, limit - open)
        guard count > left else { return nil }
        return "\(count) attempts asked, but agents may open \(left) more \(left == 1 ? "task" : "tasks") (\(open) of \(limit) open)"
    }

    /// The refusal for `call` when agents already hold `load` and it would take them past a budget, else `nil`.
    /// Only agents have budgets: what you open yourself is never counted and never refused.
    public func budgetRefusal(_ call: ControlCall, from origin: ControlOrigin, load: AutomationLoad) -> ControlError? {
        guard origin.isAgent else { return nil }
        let cost = AutomationPolicy.cost(of: call)
        if cost.tasks > 1, let refusal = AutomationPolicy.attemptsRefusal(count: cost.tasks, open: load.tasks, limit: settings.maxAgentTasks) {
            // The caller asked for N: the number tells it what N would go through, or what to archive first.
            return .denied(refusal, detail: "Ask for fewer attempts, or archive the tasks you created that are done "
                           + "(`scope task archive <slug>`, their branches are kept), or have the user raise "
                           + "Settings ▸ Automation ▸ Open tasks (now \(settings.maxAgentTasks)).")
        }
        if cost.tasks > 0, load.tasks + cost.tasks > settings.maxAgentTasks {
            return .denied(
                "agents already keep \(load.tasks) tasks open, the most Scope allows them",
                detail: "Archive the tasks you created that are done (`scope task archive <slug>`, their branches are "
                    + "kept) and ask "
                    + "again, or have the user raise Settings ▸ Automation ▸ Open tasks "
                    + "(`scope config set automation.maxAgentTasks <n>` from their own terminal, now \(settings.maxAgentTasks))."
            )
        }
        if cost.threads > 0, load.threads + cost.threads > settings.maxAgentThreads {
            return .denied(
                "agents already keep \(load.threads) threads running, the most Scope allows them",
                detail: "Wait for the threads you opened (`scope thread wait`) and close those that are done "
                    + "(`scope thread close <id>`), or have the user raise Settings ▸ Automation ▸ Running threads "
                    + "(`scope config set automation.maxAgentThreads <n>` from their own terminal, now \(settings.maxAgentThreads))."
            )
        }
        return nil
    }

    /// What should happen to `call` coming from `origin`, with `load` already held by agents.
    public func decide(_ call: ControlCall, from origin: ControlOrigin, load: AutomationLoad = .zero) -> PolicyDecision {
        guard call.method.isGated else { return .allow }

        switch origin {
        case .user:
            // The user's own terminal is the user. Automation settings govern agents, not their author.
            return .allow

        case .strangerThread(let raw):
            return .refuse(.denied(
                "SCOPE_THREAD does not name a thread this Scope knows",
                detail: "Got “\(raw)”. Only a thread Scope is running may drive it; unset SCOPE_THREAD to ask as yourself."
            ))

        case .thread, .externalAgent:
            let depth = AutomationPolicy.childDepth(of: origin) - 1
            if call.method == .configSet {
                // The settings are what holds agents in; an agent raising its own budget would make them moot.
                return .refuse(.denied(
                    "only the user may change Scope's settings",
                    detail: "Ask the user to run `scope config set …` in a terminal of their own (not a Scope thread), "
                        + "or to change it in Settings ▸ Automation."
                ))
            }
            if call.method == .taskTry {
                // The base is the user's: an agent never moves it, whatever the automation settings allow.
                return .refuse(.denied(
                    "only the user may try a task in their checkout",
                    detail: "Trying a task's branch in the base checkout is the user's own move: ask them to run "
                        + "`scope task try <task>` in a terminal of their own, or to use Try in my checkout in Scope."
                ))
            }
            guard settings.agentsMayDrive else {
                return .refuse(.denied("agents may not drive Scope",
                                       detail: "Settings ▸ Automation, or preferences.automation.agentsMayDrive in config.json."))
            }
            let approval: AutomationSettings.Approval
            switch call.method {
            case .ping, .list, .summary, .taskShow, .taskCheckpoints, .configGet, .usage:
                return .allow
            case .configSet:
                return .refuse(.denied("only the user may change Scope's settings"))
            case .taskTry:
                return .refuse(.denied("only the user may try a task in their checkout"))
            case .taskTopic:
                // A label: nothing opened, nothing removed, undone by the same call. Gating it behind the task
                // approval would ask the user about the sidebar's grouping.
                return .allow
            case .threadStop, .threadClose, .threadSend, .threadRead, .threadWait:
                // No ceiling to check — nothing new is opened — and which thread is the question: `mayTouch`
                // answers it against the target, once the app has found it.
                return .allow
            case .taskRestoreCheckpoint:
                // Files of a sandbox, with the undo taken first: an agent may do it within its own task, which the
                // app checks once it has found the task (`mayRestoreCheckpoint`). Nothing opened, nothing deleted.
                return .allow
            case .taskClose, .taskArchive, .taskRebase:
                // Undoing a task removes worktrees and can delete a branch; a rebase rewrites one and may open a
                // thread: the same approval as creating a task.
                approval = settings.tasks
            case .taskRestore:
                // A task opened again, sandboxes and all: the budget and the approval of a new one. No depth to
                // check — the task keeps the place in the chain it had, and opens no thread.
                if let refusal = budgetRefusal(call, from: origin, load: load) { return .refuse(refusal) }
                approval = settings.tasks
            case .gc:
                // A preview reads; the real pass stops processes and removes folders no task owns.
                if case .gc(let params) = call, params.dryRun { return .allow }
                approval = settings.tasks
            case .release:
                // A dry run clones and prints the plan, pushes nothing. The real one ships a version: its own
                // approval, which asks by default.
                if case .release(let params) = call, params.dryRun { return .allow }
                approval = settings.releases
            case .threadNew, .taskNew:
                let childDepth = depth + 1
                if let limit = settings.depthLimit, childDepth > limit {
                    return .refuse(.denied(
                        "\(AutomationPolicy.describe(origin, depth: depth)) may not open another",
                        detail: "The chain would reach depth \(childDepth), past the limit of \(limit) the user set in "
                            + "Settings ▸ Automation ▸ Depth (preferences.automation.depthLimit)."
                    ))
                }
                if let refusal = budgetRefusal(call, from: origin, load: load) { return .refuse(refusal) }
                approval = call.method == .threadNew ? settings.threads : settings.tasks
            }
            return switch approval {
            case .allow: .allow
            case .ask: .ask(subject: AutomationPolicy.subject(of: call))
            case .deny: .refuse(.denied("\(call.method.rawValue) is turned off for agents",
                                        detail: "Settings ▸ Automation."))
            }
        }
    }

    /// Whether `origin` may stop, close, type into or read the thread `id`, which `target` says was opened by whom.
    ///
    /// You may touch any thread. With `reach` at `any`, so may an agent — bar itself: a thread typing into its
    /// own terminal is a prompt loop with no one at the keyboard. With `own`, an agent may touch only what it set in
    /// motion: the threads it opened, the threads those opened, and so on down — an orchestrator must be able to
    /// wait for the grandchild its task started. Not a sibling's, not its parent's. An agent outside Scope, which has
    /// no thread of its own to be the ancestor of anything, only the threads agents outside Scope opened.
    public static func mayTouch(_ target: ThreadOrigin, id: ThreadID? = nil, from origin: ControlOrigin,
                                reach: AutomationSettings.ThreadReach = .own) -> ControlError? {
        switch origin {
        case .user:
            return nil
        case .strangerThread(let raw):
            return .denied("SCOPE_THREAD does not name a thread this Scope knows", detail: "Got “\(raw)”.")
        case .thread(let own, _):
            if let id, id == own {
                return .badRequest("a thread may not act on itself",
                                   detail: "The message would land in your own terminal. Pick another thread from `scope list threads`.")
            }
            guard reach == .own else { return nil }
            guard target.lineage.contains(own.rawValue) else {
                return .denied("an agent may only act on the threads it opened and the ones those opened",
                               detail: "Ask the user, or use `scope list threads` to find the ones you opened. "
                                   + "Settings ▸ Automation ▸ Talking to threads opens every thread.")
            }
            return nil
        case .externalAgent:
            guard reach == .own else { return nil }
            let openedOutside = target.author == .control && target.parent == nil
                && (target.client ?? "").hasPrefix(ControlClientName.mcp + "/")
            guard openedOutside else {
                return .denied("an agent outside Scope may only act on threads agents outside Scope opened",
                               detail: "The threads you or a Scope thread opened are not yours to stop, close or type into. "
                                   + "Settings ▸ Automation ▸ Talking to threads opens every thread.")
            }
            return nil
        }
    }

    /// Whether `origin` may restore a checkpoint of the task `taskID`, whose threads are `taskThreads`: you may, and so
    /// may an agent whose own thread runs in that task — not another task's, not an agent outside Scope.
    public static func mayRestoreCheckpoint(of taskID: String, taskThreads: [ThreadID], from origin: ControlOrigin) -> ControlError? {
        switch origin {
        case .user:
            return nil
        case .strangerThread(let raw):
            return .denied("SCOPE_THREAD does not name a thread this Scope knows", detail: "Got “\(raw)”.")
        case .thread(let own, _):
            guard taskThreads.contains(own) else {
                return .denied("an agent may only restore a checkpoint of its own task",
                               detail: "The task \(taskID) is not the one your thread runs in. Ask the user, or its own thread.")
            }
            return nil
        case .externalAgent:
            return .denied("an agent outside Scope may not restore a checkpoint",
                           detail: "Restoring rewrites a sandbox's files; only the user or the task's own thread may.")
        }
    }

    /// Who is asking, in the words of a refusal.
    static func describe(_ origin: ControlOrigin, depth: Int) -> String {
        switch origin {
        case .externalAgent: "an agent outside Scope"
        default: depth == 0 ? "an agent opened by you" : "an agent at depth \(depth)"
        }
    }

    /// One line saying what is being asked for, shown in the confirmation.
    static func subject(of call: ControlCall) -> String {
        switch call {
        case .ping, .list, .summary, .configGet, .usage: ""
        case .taskShow(let params): "show the task “\(params.task)”"
        case .configSet(let params): "set \(params.key) to \(params.value)"
        case .threadNew(let params):
            "open a thread" + (params.scope.map { " in \($0)" } ?? "")
        case .taskNew(let params):
            "create the task “\(params.title ?? params.prompt.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines))”"
        case .taskClose(let params):
            "close the task “\(params.task)”" + (params.deleteBranch ? " and delete its branch" : "")
        case .taskArchive(let params): "archive the task “\(params.task)”"
        case .taskRestore(let params): "restore the archived task “\(params.task)”"
        case .taskRebase(let params): "rebase " + (params.task.map { "the task “\($0)”" } ?? "its own task") + " on main"
        case .taskTry(let params):
            params.end ? "put your checkout back from the task “\(params.task)”"
                : params.refresh ? "move your checkout to the head of the task “\(params.task)”"
                : "try the task “\(params.task)” in your checkout"
        case .taskCheckpoints(let params): "list the checkpoints of " + (params.task.map { "the task “\($0)”" } ?? "its own task")
        case .taskRestoreCheckpoint(let params):
            "restore checkpoint \(params.number) of " + (params.task.map { "the task “\($0)”" } ?? "its own task")
        case .taskTopic(let params):
            "file " + (params.task.map { "the task “\($0)”" } ?? "its own task") + " "
                + (params.topic.map { "under “\($0)”" } ?? "out of its topic")
        case .gc: "clean up leftover sandboxes and processes"
        case .release(let params):
            "release " + (params.repo.map { "\($0) " } ?? "") + (params.version.map { "v\($0)" } ?? "the next version")
                + (params.scope.map { " in \($0)" } ?? "") + (params.force ? ", CI unchecked" : "")
        case .threadStop(let params): "stop the thread \(params.thread)"
        case .threadClose(let params): "close the thread \(params.thread)"
        case .threadSend(let params): (params.command ? "run a driver command in the thread " : "type into the thread ") + params.thread
        case .threadRead(let params): "read the thread \(params.thread)"
        case .threadWait(let params): "wait for " + params.threads.joined(separator: ", ")
        }
    }
}
