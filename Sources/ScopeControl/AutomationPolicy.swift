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
            let childDepth = depth + 1
            guard childDepth <= settings.maxDepth else {
                return .refuse(.denied(
                    "\(AutomationPolicy.describe(origin, depth: depth)) may not open another",
                    detail: "The chain would reach depth \(childDepth), past the ceiling of \(settings.maxDepth). "
                        + "Raise preferences.automation.maxDepth if that is what you want."
                ))
            }
            let approval = switch call.method {
            case .threadNew: settings.threads
            case .taskNew: settings.tasks
            case .ping, .list: AutomationSettings.Approval.allow
            }
            return switch approval {
            case .allow: .allow
            case .ask: .ask(subject: AutomationPolicy.subject(of: call))
            case .deny: .refuse(.denied("\(call.method.rawValue) is turned off for agents",
                                        detail: "Settings ▸ Automation."))
            }
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
        }
    }
}
