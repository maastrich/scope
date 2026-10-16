import Foundation
import ScopeCore
import ScopeTasks

/// Markdown the reading column shows: an agent's last answer, what a task kept at archive, a task's brief.
struct ReadingContent: Equatable {
    enum Kind: Equatable {
        /// The last reply of a thread, read live from its activity.
        case reply(ThreadID)
        /// What was kept of a task when it was archived or closed.
        case deliverable(TaskID)
        /// The prompt a task was created from.
        case brief(TaskID)
        /// A checkpoint of a task against its sandboxes now (`AppModel+Checkpoints`).
        case checkpoint(TaskID, Int)
    }

    var kind: Kind
    /// `Claude Code · auth-refresh`: what the text is and where it comes from.
    var title: String
    /// When the answer was given, for a reply.
    var at: Date?
    /// A reply still being written: the text grows with the agent's `turn.said` events (`AppModel.refreshReading`).
    var isLive = false
    var markdown: String
    /// Where relative file links resolve from (`FileLinkResolver`): the thread's directory, or the task's root.
    var directory: String?
    /// The task whose sandboxes a file link may point into, when there is one.
    var taskID: TaskID?
    var scopeID: ScopeID

    var icon: String {
        switch kind {
        case .reply: "text.bubble"
        case .deliverable: "doc.richtext"
        case .brief: "text.quote"
        case .checkpoint: "clock.arrow.circlepath"
        }
    }
}
