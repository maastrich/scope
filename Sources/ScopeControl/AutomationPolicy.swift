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
/// Pure and testable on its own: the app hands it the settings and the resolved origin, it answers what to
/// do. The two things it exists for are the recursion ceiling — an agent opening agents opening agents — and
/// the fact that creating a task writes branches and worktrees into the user's repositories.
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

    /// What should happen to `call` coming from `origin`.
    public func decide(_ call: ControlCall, from origin: ControlOrigin) -> PolicyDecision {
        guard call.method.isMutating else { return .allow }

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
            guard settings.agentsMayDrive else {
                return .refuse(.denied("agents may not drive Scope",
                                       detail: "Settings ▸ Automation, or preferences.automation.agentsMayDrive in config.json."))
            }
            let approval: AutomationSettings.Approval
            switch call.method {
            case .ping, .list:
                return .allow
            case .threadStop, .threadClose, .threadSend:
                // No ceiling to check — nothing new is opened — and which thread is the question: `mayTouch`
                // answers it against the target, once the app has found it.
                return .allow
            case .taskClose:
                // Undoing a task removes worktrees and can delete a branch: the same approval as creating one.
                approval = settings.tasks
            case .threadNew, .taskNew:
                let childDepth = depth + 1
                guard childDepth <= settings.maxDepth else {
                    return .refuse(.denied(
                        "\(AutomationPolicy.describe(origin, depth: depth)) may not open another",
                        detail: "The chain would reach depth \(childDepth), past the ceiling of \(settings.maxDepth). "
                            + "Raise preferences.automation.maxDepth if that is what you want."
                    ))
                }
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

    /// Whether `origin` may stop, close or type into a thread that `target` says was opened by whom.
    ///
    /// You may touch any thread. An agent may touch only the threads it opened itself — typing into another
    /// agent's terminal is a prompt it never agreed to — and an agent outside Scope, which has no thread of its
    /// own to be the parent of anything, only the threads agents outside Scope opened.
    public static func mayTouch(_ target: ThreadOrigin, from origin: ControlOrigin) -> ControlError? {
        switch origin {
        case .user:
            return nil
        case .strangerThread(let raw):
            return .denied("SCOPE_THREAD does not name a thread this Scope knows", detail: "Got “\(raw)”.")
        case .thread(let id, _):
            guard target.parent == id.rawValue else {
                return .denied("an agent may only act on the threads it opened",
                               detail: "Ask the user, or use `scope list threads` to find the ones you opened.")
            }
            return nil
        case .externalAgent:
            let openedOutside = target.author == .control && target.parent == nil
                && (target.client ?? "").hasPrefix(ControlClientName.mcp + "/")
            guard openedOutside else {
                return .denied("an agent outside Scope may only act on threads agents outside Scope opened",
                               detail: "The threads you or a Scope thread opened are not yours to stop, close or type into.")
            }
            return nil
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
        case .ping, .list: ""
        case .threadNew(let params):
            "open a thread" + (params.scope.map { " in \($0)" } ?? "")
        case .taskNew(let params):
            "create the task “\(params.title ?? params.prompt.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines))”"
        case .taskClose(let params):
            "close the task “\(params.task)”" + (params.deleteBranch ? " and delete its branch" : "")
        case .threadStop(let params): "stop the thread \(params.thread)"
        case .threadClose(let params): "close the thread \(params.thread)"
        case .threadSend(let params): "type into the thread \(params.thread)"
        }
    }
}
