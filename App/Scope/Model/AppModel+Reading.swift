import AppKit
import Foundation
import ScopeCore
import ScopeTasks

/// The reading column's Markdown: a thread's last answer, what a task kept at archive, a task's brief.
extension AppModel {
    /// The answer of `session`, rendered in the reading column: the one being written when its driver reports it
    /// (`ThreadActivity.saying`), else the last one. Nothing to read opens the column all the same, saying so: a
    /// shortcut that does nothing is a shortcut the user thinks is broken.
    func readReply(of session: ThreadSession) {
        showReading(replyContent(of: session))
    }

    /// The reading column follows the thread it shows: a piece of the answer, its end, or a new prompt moves the
    /// text. Nothing happens when the column shows something else, or another thread.
    func refreshReading(for session: ThreadSession) {
        guard inspector.reading?.kind == .reply(session.id) else { return }
        let next = replyContent(of: session)
        if next != inspector.reading { inspector.reading = next }
    }

    private func replyContent(of session: ThreadSession) -> ReadingContent {
        let taskState = task(of: session)
        let directory = session.agentDirectory ?? session.reportedDirectory ?? session.record.cwd
        let title = "\(displayTitle(for: session)) · \(session.profile.name)"
        if let saying = session.activity.saying, !saying.text.isEmpty {
            return ReadingContent(kind: .reply(session.id), title: title, at: saying.at, isLive: true, markdown: saying.text,
                                  directory: directory, taskID: taskState?.id, scopeID: session.record.scopeID)
        }
        let reply = session.activity.lastReply ?? session.lastReply
        return ReadingContent(kind: .reply(session.id), title: title, at: reply?.at,
                              markdown: reply?.text ?? Self.noReplyText(session), directory: directory,
                              taskID: taskState?.id, scopeID: session.record.scopeID)
    }

    /// ⇧⌘R: the selected thread's answer, or the only thread of the selected task.
    func readCurrentReply() {
        guard let session = currentThread ?? currentTask.flatMap({ threads(in: $0.id).first }) else { return }
        readReply(of: session)
    }

    /// What `task` kept when it was archived or closed (`TaskDeliverable`): its report file and its threads' last
    /// answers, as one page. `nil` when nothing was kept — the caller hides the control.
    func deliverable(of task: TaskState) -> TaskDeliverable? {
        TaskDeliverableStore.load(home: env.home, taskID: task.id.rawValue)
    }

    func readDeliverable(of task: TaskState) {
        guard let kept = deliverable(of: task) else { return }
        Usage.click("task.read-deliverable", label: "Read a task's deliverable")
        showReading(ReadingContent(
            kind: .deliverable(task.id), title: "\(task.name) · deliverable", at: kept.lastReply?.at ?? kept.savedAt,
            markdown: kept.markdown, directory: task.record.threadCwd.path, taskID: task.id, scopeID: task.scopeID
        ))
    }

    /// The whole brief of `task`, from the inspector's Task section.
    func readBrief(of task: TaskState) {
        guard let prompt = task.record.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return }
        Usage.click("task.read-brief", label: "Read a task's brief in full")
        showReading(ReadingContent(
            kind: .brief(task.id), title: "\(task.name) · brief", at: task.record.createdAt, markdown: prompt,
            directory: task.record.threadCwd.path, taskID: task.id, scopeID: task.scopeID
        ))
    }

    /// The reading column stands on its own: it opens beside the terminal whether the inspector is shown or not
    /// (`RootView`), so reading an answer never brings the inspector along.
    func showReading(_ content: ReadingContent) {
        inspector.reading = content
        inspector.show(.reading)
    }

    /// A link clicked in rendered Markdown: the browser for the web, the viewer column for a file it can find.
    /// Anything else is left alone — the text is an agent's.
    func openMarkdownLink(_ url: URL, in content: ReadingContent) {
        switch MarkdownLink.classify(url.absoluteString) {
        case .web(let web):
            NSWorkspace.shared.open(web)
        case .file(let path):
            let taskState = content.taskID.flatMap(task)
            if !openFileLink(path, scope: content.scopeID, task: taskState, directory: content.directory) {
                problems.warn("No file called \(path)", detail: "The link in the text names nothing on disk.")
            }
        case .refused:
            break
        }
    }

    static func noReplyText(_ session: ThreadSession) -> String {
        if !session.deliversEvents {
            return "_\(session.profile.name) does not report its answers to Scope: there is nothing to read here. Its terminal has them._"
        }
        return "_No answer yet. The agent's last reply shows here once a turn has ended._"
    }
}
