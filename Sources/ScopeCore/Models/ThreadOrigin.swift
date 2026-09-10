import Foundation

/// Who opened a thread, and how far down the chain of agents it sits.
///
/// A thread the user opened is at depth 0. A thread an agent opened from inside it is at depth 1, and so on:
/// this is what the automation ceiling counts (see `AutomationSettings.maxDepth`). Stored on the record so
/// the count survives a restart — an agent that could reset the chain by relaunching the app would be no
/// ceiling at all.
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

    public init(author: Author, parent: String? = nil, depth: Int = 0, client: String? = nil) {
        self.author = author
        self.parent = parent
        self.depth = max(0, depth)
        self.client = client
    }

    /// The user, in the app.
    public static let user = ThreadOrigin(author: .user)

    /// What a record without the key means: a thread from before origins were recorded, hence the user's.
    public static let unknown = ThreadOrigin(author: .user)
}
