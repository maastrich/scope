import Foundation
import ScopeAdapters
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
    /// For a reply: what the turn ran, what it changed, and the turns before it (`ReadingTurn`).
    var turn: ReadingTurn?
    var markdown: String
    /// Where relative file links resolve from (`FileLinkResolver`): the thread's directory, or the task's root.
    var directory: String?
    /// The task whose sandboxes a file link may point into, when there is one.
    var taskID: TaskID?
    var scopeID: ScopeID

    var icon: String {
        if turn?.historyIndex != nil { return "clock" }
        return switch kind {
        case .reply: "text.bubble"
        case .deliverable: "doc.richtext"
        case .brief: "text.quote"
        case .checkpoint: "clock.arrow.circlepath"
        }
    }
}

/// Around a reply: the tool calls of its turn, the checkpoint the turn left, and the session's earlier turns.
struct ReadingTurn: Equatable {
    struct Call: Equatable, Identifiable {
        var id: Int
        var name: String
        var target: String?
        var durationMs: Int?
    }

    /// The checkpoint a turn left (`TaskCheckpoint`): what the column says the turn changed.
    struct Changes: Equatable {
        var taskID: TaskID
        var number: Int
        var additions: Int
        var deletions: Int
        /// The task's sandboxes that changed, by name.
        var repos: [String]
    }

    struct HistoryTurn: Equatable, Identifiable {
        var id: Int
        var prompt: String
        var reply: String
        var tools: Int
        var at: Date?
    }

    var calls: [Call] = []
    var changes: Changes?
    /// Earlier turns of the session, oldest first (`TranscriptReader`); empty while unread or unreadable.
    var history: [HistoryTurn] = []
    /// Which history turn the column shows; `nil` for the latest answer.
    var historyIndex: Int?
    /// The transcript could not be read: the history list says so instead of staying empty without a word.
    var historyUnavailable = false
}
