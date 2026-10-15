import Foundation

/// Who opened a thread, and how far down the chain of agents it sits.
///
/// A thread the user opened is at depth 0. A thread an agent opened from inside it is at depth 1, and so on:
/// what `scope list` shows and what the optional depth limit counts (`AutomationSettings.depthLimit`). Stored on
/// the record so the count survives a restart — an agent that could reset the chain by relaunching the app would
/// escape the limit.
public struct ThreadOrigin: Codable, Sendable, Equatable {
    /// Who asked for the thread.
    public enum Author: String, Codable, Sendable {
        /// The user, in the app.
        case user
        /// A control request on the socket (the `scope` CLI, `scope mcp`).
        case control

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Author(rawValue: raw) ?? .control
        }
    }

    public var author: Author
    /// Raw id of the thread whose agent asked for this one; `nil` when the request came from a terminal.
    public var parent: String?
    /// 0 for a thread the user opened, +1 per generation below.
    public var depth: Int
    /// What made the request: `scope-cli/0.3.1`, `scope-mcp/0.3.1`.
    public var client: String?
    /// The raw ids above `parent`, nearest first: who opened the parent, who opened that one… Copied down at
    /// creation, so a closed thread in the middle of the chain does not cut its descendants off from the agent
    /// that started them. `nil` on records written before it existed.
    public var ancestors: [String]?

    /// How many generations `ancestors` keeps. A chain longer than this is a loop the budgets already stopped.
    public static let lineageLimit = 32

    public init(author: Author, parent: String? = nil, depth: Int = 0, client: String? = nil,
                ancestors: [String]? = nil) {
        self.author = author
        self.parent = parent
        self.depth = max(0, depth)
        self.client = client
        self.ancestors = ancestors.map { Array($0.prefix(ThreadOrigin.lineageLimit)) }
    }

    /// Every thread above this one, nearest first: the parent, then `ancestors`.
    public var lineage: [String] {
        guard let parent else { return [] }
        return [parent] + (ancestors ?? [])
    }

    /// The origin of a thread opened by the thread `parent`, whose own origin is `parentOrigin`.
    public static func child(of parent: String, origin parentOrigin: ThreadOrigin?, depth: Int,
                             client: String?) -> ThreadOrigin {
        ThreadOrigin(author: .control, parent: parent, depth: depth, client: client,
                     ancestors: parentOrigin?.lineage ?? [])
    }

    /// The user, in the app.
    public static let user = ThreadOrigin(author: .user)

    /// What a record without the key means: a thread from before origins were recorded, hence the user's.
    public static let unknown = ThreadOrigin(author: .user)
}

extension ThreadOrigin {
    /// What `scope mcp` puts before its version in `client` (`ControlClientName.mcp`, which this module cannot see).
    public static let mcpClientPrefix = "scope-mcp/"

    /// Whether an agent asked for this thread — the question the sidebar's origin marker answers.
    ///
    /// Not `author == .control` alone: that is also you typing `scope thread new` in a terminal of your own,
    /// which `AutomationPolicy.origin` already counts as the user. An agent is a thread of this app (it has a
    /// `parent`) or `scope mcp` reached from a session outside it.
    public var openedByAgent: Bool {
        guard author == .control else { return false }
        return parent != nil || (client ?? "").hasPrefix(ThreadOrigin.mcpClientPrefix)
    }
}
