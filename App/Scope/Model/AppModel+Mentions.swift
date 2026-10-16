import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks

/// `@task:<slug>` and `@thread:<id>` in what goes to an agent (`TaskMention`): the lookups behind the pure expansion.
/// A task is found among the live records, then the history of closed ones, the way `scope task show` finds it; a
/// thread among the sessions, then the history.
extension AppModel {
    /// `text` with its mentions expanded; `text` itself when it holds none, without touching the disk.
    func expandMentions(_ text: String) async -> String {
        guard TaskMention.mentions(text) else { return text }
        let scopes = self.scopes.map { ActivitySummary.ScopeRef(id: $0.id.rawValue, slug: $0.declaration.slug, name: $0.name, root: $0.url.path) }
        let tasks = await env.tasks.allTasks.map(\.snapshot)
        let threads = self.threads.map(\.record.snapshot)
        let home = env.home
        let (history, deliverables) = await Task.detached {
            (ActivityHistory.load(home: home), TaskDeliverableStore.loadAll(home: home))
        }.value
        return TaskMention.expand(text, task: { name in
            ActivitySummary.show(name, scopes: scopes, tasks: tasks, threads: threads, history: history, deliverables: deliverables)
                .map(TaskMention.TaskBlock.init)
        }, thread: { raw in
            if let id = ThreadID(rawValue: raw), let session = session(id) {
                let task = session.record.taskID.flatMap { taskID in self.tasks.first { $0.record.id.rawValue == taskID } }
                return TaskMention.ThreadBlock(id: raw, title: session.title, driver: session.record.driverID, task: task?.record.slug,
                                               state: session.displayState.name,
                                               reply: (session.activity.lastReply ?? session.lastReply)?.text)
            }
            guard let closed = history.last(where: { $0.kind == .threadClosed && $0.thread?.id == raw })?.thread else { return nil }
            let task = tasks.first { $0.id == closed.taskID }
            return TaskMention.ThreadBlock(id: raw, title: closed.title, driver: closed.driverID, task: task?.slug, state: "closed")
        })
    }

    /// The tasks a message field offers after `@`, in `scope`: open ones first, newest first, then the archived.
    func mentionCandidates(in scopeID: ScopeID?) -> [MentionQuery.Candidate] {
        let pool = scopeID.map { id in tasks.filter { $0.scopeID == id } } ?? tasks
        let ordered = pool.filter { !$0.record.isArchived }.sorted { $0.record.createdAt > $1.record.createdAt }
            + pool.filter(\.record.isArchived).sorted { ($0.record.archivedAt ?? .distantPast) > ($1.record.archivedAt ?? .distantPast) }
        return ordered.map { MentionQuery.Candidate(slug: $0.record.slug, name: $0.name, archived: $0.record.isArchived) }
    }
}
