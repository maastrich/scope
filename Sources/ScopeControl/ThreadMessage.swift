import Foundation
import ScopeCore

/// Who typed into a thread, as the receiving agent reads it.
///
/// A prompt that arrives from another agent looks exactly like one the user typed, so the text carries its
/// sender: the receiving agent then knows whom to answer — `scope thread send <id>` back — and that the
/// request is not the user's. The user's own terminal is never wrapped: what they type is theirs.
public enum ThreadMessage {
    /// The sender named in the envelope.
    public struct Sender: Sendable, Equatable {
        /// A thread Scope runs.
        public struct Thread: Sendable, Equatable {
            public var id: String
            public var title: String
            /// The slug of the task the sender works in, when it works in one.
            public var task: String?
            /// The scope of the sender, named when it differs from the receiver's.
            public var scope: String?

            public init(id: String, title: String, task: String? = nil, scope: String? = nil) {
                self.id = id
                self.title = title
                self.task = task
                self.scope = scope
            }
        }

        public var thread: Thread?
        /// The client of an agent outside Scope (`scope-mcp/0.9.0`).
        public var client: String

        public init(thread: Thread? = nil, client: String) {
            self.thread = thread
            self.client = client
        }
    }

    /// `text` with the line saying who sent it, ready to be typed.
    ///
    /// The envelope is one line on its own, so a driver whose prompt box is one line still shows the message
    /// after it. Only a submitted message is wrapped: text sent without ↩ is keystrokes, not a message.
    public static func envelope(_ text: String, from sender: Sender) -> String {
        "\(header(for: sender))\n\(text)"
    }

    /// The first line of the envelope.
    public static func header(for sender: Sender) -> String {
        guard let thread = sender.thread else {
            return "[Scope: message from an agent outside Scope (\(sender.client)); answer it through the user]"
        }
        var where_: [String] = []
        if let task = thread.task { where_.append("task \(task)") }
        if let scope = thread.scope { where_.append("scope \(scope)") }
        let place = where_.isEmpty ? "" : ", " + where_.joined(separator: ", ")
        return "[Scope: message from thread \(thread.id) “\(thread.title)”\(place); "
            + "reply with `scope thread send \(thread.id) <text>`]"
    }
}
