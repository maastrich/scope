import AppKit
import Foundation
import ScopeAdapters
import ScopeCore
import ScopeTasks

/// The reading column's Markdown: a thread's last answer, what a task kept at archive, a task's brief.
extension AppModel {
    /// The answer of `session`, rendered in the reading column: the one being written when its driver reports it
    /// (`ThreadActivity.saying`), else the last one. Nothing to read opens the column all the same, saying so: a
    /// shortcut that does nothing is a shortcut the user thinks is broken.
    func readReply(of session: ThreadSession) {
        showReading(replyContent(of: session))
        loadReplyHistory(of: session)
    }

    /// An earlier turn of the session, from the history under the answer; `nil` goes back to the latest answer.
    func readHistoryTurn(_ index: Int?, of session: ThreadSession) {
        guard inspector.reading?.kind == .reply(session.id) else { return }
        inspector.reading = replyContent(of: session, historyIndex: index)
    }

    /// The reading column follows the thread it shows: a piece of the answer, its end, or a new prompt moves the
    /// text. Nothing happens when the column shows something else, or another thread; a history turn being read
    /// stays, its list refreshed. A turn that ended is a turn the transcript now has: read it again.
    func refreshReading(for session: ThreadSession, turnEnded: Bool = false) {
        guard let shown = inspector.reading, shown.kind == .reply(session.id) else { return }
        let next = replyContent(of: session, historyIndex: shown.turn?.historyIndex)
        if next != shown { inspector.reading = next }
        if turnEnded { loadReplyHistory(of: session) }
    }

    private func replyContent(of session: ThreadSession, historyIndex: Int? = nil) -> ReadingContent {
        let taskState = task(of: session)
        let directory = session.agentDirectory ?? session.reportedDirectory ?? session.record.cwd
        let title = "\(displayTitle(for: session)) · \(session.profile.name)"
        var turn = ReadingTurn(history: historyTurns(of: session, historyIndex: historyIndex),
                               historyUnavailable: replyHistoryUnavailable.contains(session.id))
        if let index = historyIndex, let past = replyHistory[session.id], past.indices.contains(index) {
            // An earlier turn, as the transcript has it: its prompt quoted over its answer, its tools from the same file.
            let old = past[index]
            turn.historyIndex = index
            turn.calls = old.calls.enumerated().map { ReadingTurn.Call(id: $0.offset, name: $0.element.name, target: $0.element.target) }
            let prompt = old.prompt.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            let markdown = prompt + "\n\n" + (old.reply.isEmpty ? "_The agent only ran tools in this turn._" : old.reply)
            return ReadingContent(kind: .reply(session.id), title: "\(title) · turn \(index + 1)", at: old.endedAt, turn: turn,
                                  markdown: markdown, directory: directory, taskID: taskState?.id, scopeID: session.record.scopeID)
        }
        let activity = session.activity
        turn.calls = activity.currentCalls.enumerated().map {
            ReadingTurn.Call(id: $0.offset, name: $0.element.name, target: $0.element.target, durationMs: $0.element.durationMs)
        }
        if !activity.inTurn, let taskState, let last = activity.turns.last, last.outcome == .ended || last.outcome == .failed,
           let checkpoint = taskState.checkpoints.last(where: { $0.threadID == session.id.rawValue && $0.turn == activity.turns.count }) {
            turn.changes = ReadingTurn.Changes(taskID: taskState.id, number: checkpoint.number, additions: checkpoint.additions,
                                               deletions: checkpoint.deletions,
                                               repos: checkpoint.repos.filter { $0.additions + $0.deletions > 0 }.map(\.repoRelativePath))
        }
        if let saying = activity.saying, !saying.text.isEmpty {
            return ReadingContent(kind: .reply(session.id), title: title, at: saying.at, isLive: true, turn: turn, markdown: saying.text,
                                  directory: directory, taskID: taskState?.id, scopeID: session.record.scopeID)
        }
        let reply = activity.lastReply ?? session.lastReply
        return ReadingContent(kind: .reply(session.id), title: title, at: reply?.at, turn: turn,
                              markdown: reply?.text ?? Self.noReplyText(session), directory: directory,
                              taskID: taskState?.id, scopeID: session.record.scopeID)
    }

    /// The session's turns, one line each. Under the latest answer, the transcript's last turn *is* that answer
    /// when it began after the thread's last turn did: it is left out, "earlier" meaning earlier.
    private func historyTurns(of session: ThreadSession, historyIndex: Int?) -> [ReadingTurn.HistoryTurn] {
        var past = replyHistory[session.id] ?? []
        let activity = session.activity
        if historyIndex == nil, !activity.inTurn, let last = past.last, let shown = activity.turns.last,
           let ended = last.endedAt, ended >= (shown.startedAt ?? shown.endedAt) {
            past.removeLast()
        }
        return past.enumerated().map { index, turn in
            ReadingTurn.HistoryTurn(id: index, prompt: ThreadActivity.excerpt(turn.prompt, limit: 100) ?? "",
                                    reply: ThreadActivity.excerpt(MarkdownDocument.parse(turn.reply).plainText, limit: 100) ?? "",
                                    tools: turn.calls.count, at: turn.endedAt)
        }
    }

    /// Reads the session's transcript off the main thread and refreshes the column once it is in. One read at a
    /// time per thread; a thread without a transcript (no hook yet, another driver) is left alone.
    func loadReplyHistory(of session: ThreadSession) {
        guard replyHistoryJobs[session.id] == nil, let path = session.activity.transcriptPath else { return }
        let id = session.id, url = URL(fileURLWithPath: path)
        replyHistoryJobs[id] = Task { [weak self] in
            let turns = await Task.detached(priority: .utility) { try? TranscriptReader.read(url) }.value
            guard let self else { return }
            replyHistoryJobs[id] = nil
            if let turns {
                replyHistory[id] = turns
                replyHistoryUnavailable.remove(id)
            } else {
                replyHistoryUnavailable.insert(id)
            }
            if let session = self.session(id) { refreshReading(for: session) }
        }
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

    /// A context file of `task` — the one Scope wrote, or the repository's own — from the Context card. Read on the
    /// spot: it is a page of Markdown, and the agent may have just rewritten it.
    func readContextFile(_ entry: TaskContextFiles.Entry, of task: TaskState) {
        guard let markdown = try? String(contentsOf: entry.url, encoding: .utf8) else {
            problems.warn("Cannot read \(entry.name)", detail: "The file at \(entry.url.path) could not be read.")
            return
        }
        Usage.click("task.read-context-file", label: "Read a task's context file")
        let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        showReading(ReadingContent(
            kind: .contextFile(task.id, entry.url.path), title: "\(task.name) · \(entry.name)", at: modified, markdown: markdown,
            directory: entry.url.deletingLastPathComponent().path, taskID: task.id, scopeID: task.scopeID
        ))
    }

    /// What `task`'s agent was given to read, as the Context card lists it: the context files where its threads
    /// start, Scope's own first, then the repository's; and the skills its sandboxes hold.
    func contextFiles(of task: TaskState) -> [TaskContextFiles.Entry] {
        TaskContextFiles.offered(task: task.record, declared: contextFileNames, probe: TaskContextFiles.diskProbe)
    }

    func skills(of task: TaskState) -> [String] {
        TaskContextFiles.skills(task: task.record, children: TaskContextFiles.diskChildren, isSkill: TaskContextFiles.diskIsSkill)
    }

    /// The setup log of `task`, from the Setup line of the Environment card: what its commands printed, as one
    /// code block, growing while the setup runs (`refreshSetupLogReading`).
    func readSetupLog(of task: TaskState) {
        Usage.click("task.read-setup-log", label: "Read a task's setup log")
        showReading(setupLogContent(of: task))
    }

    /// The task's record changed: a setup log being read follows it.
    func refreshSetupLogReading(of task: TaskState) {
        guard let shown = inspector.reading, shown.kind == .setupLog(task.id) else { return }
        let next = setupLogContent(of: task)
        if next != shown { inspector.reading = next }
    }

    private func setupLogContent(of task: TaskState) -> ReadingContent {
        let setup = task.record.setup
        let log = setup?.log.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let markdown: String
        switch setup?.state {
        case .none, .notRun: markdown = "_The setup has not run yet._"
        case .skipped where log.isEmpty: markdown = "_Nothing to run: the task's repositories declare no setup command._"
        case .running where log.isEmpty: markdown = "_The setup is running; its output lands here._"
        default: markdown = "```\n" + log.replacingOccurrences(of: "```", with: "`\u{200B}``") + "\n```"
        }
        return ReadingContent(kind: .setupLog(task.id), title: "\(task.name) · setup log",
                              at: setup?.finishedAt ?? setup?.startedAt, isLive: setup?.state == .running,
                              markdown: markdown, directory: task.record.threadCwd.path, taskID: task.id, scopeID: task.scopeID)
    }

    /// The reading column stands on its own: it opens beside the terminal whether the inspector is shown or not
    /// (`RootView`), so reading an answer never brings the inspector along.
    func showReading(_ content: ReadingContent) {
        inspector.reading = content
        inspector.show(.reading)
    }

    /// A link clicked in rendered Markdown: the Browser pane or the system browser for the web (`BrowserRoute`), the viewer column for a file it can find.
    /// Anything else is left alone — the text is an agent's.
    func openMarkdownLink(_ url: URL, in content: ReadingContent) {
        switch MarkdownLink.classify(url.absoluteString) {
        case .web(let web):
            if !openWebLink(web.absoluteString, task: content.taskID.flatMap(task)) { NSWorkspace.shared.open(web) }
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
