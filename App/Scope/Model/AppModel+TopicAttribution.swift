import Foundation
import ScopeCore
import ScopeTasks

/// Scope's own grouping of tasks into topics (`TopicAttribution`): nothing at creation for a task on its own, a topic
/// born with the sibling, explicit choices left alone. Runs when a task is created and when its pull requests change
/// (a stack only shows once both have one); the assistant is asked only at creation, and only when no strong link
/// decided already.
extension AppModel {
    /// The open tasks of `scope` as the attribution reads them.
    func topicMembers(in scope: ScopeID) -> [TopicAttribution.Member] {
        tasks(in: scope).map { TopicAttribution.Member($0.record) }
    }

    /// The open tasks a new one could go with by its brief, for the assistant.
    func topicCandidates(for task: TaskState) -> [TaskState] {
        let ids = TopicAttribution.candidates(for: task.id.rawValue, among: topicMembers(in: task.scopeID)).map(\.id)
        return ids.compactMap { id in tasks.first { $0.id.rawValue == id } }
    }

    /// A task was just created: grouped with what it is strongly linked to, else — unless someone filed it — offered
    /// to the assistant against the open tasks' briefs.
    func attributeTopic(createdTask task: TaskState) {
        guard !task.record.topicIsExplicit else { return }
        Task { [weak self] in
            guard let self else { return }
            let applied = await self.attributeTopics(in: task.scopeID)
            guard !applied, self.task(task.id)?.record.topic == nil else { return }
            self.assistTaskCreated(task, candidates: !self.topicCandidates(for: task).isEmpty)
        }
    }

    /// Applies what `TopicAttribution.decide` says for `scope`, with `extra` links on top of the strong ones (the
    /// assistant's). Returns whether anything moved.
    @discardableResult
    func attributeTopics(in scope: ScopeID, extra: [TopicAttribution.Link] = []) async -> Bool {
        let members = topicMembers(in: scope)
        let decisions = TopicAttribution.decide(members, links: TopicAttribution.strongLinks(members) + extra)
        var applied = false
        for decision in decisions {
            switch decision {
            case .file(let ids, let topic):
                let movable = movableTasks(ids)
                guard !movable.isEmpty else { continue }
                await setTopic(topic, source: .automatic, for: movable)
                logTopic("filed", topic: topic, count: movable.count)
                applied = true
            case .create(let ids, let hint):
                let states = ids.compactMap { id in tasks.first { $0.id.rawValue == id } }
                let name: String? = if let hint { hint } else { await topicName(for: states) }
                guard let name else { continue }
                let topic = TopicName.reuse(name, among: knownTopics(in: scope))
                // The assistant took a moment: someone may have filed one of them meanwhile, and theirs wins.
                let movable = movableTasks(ids)
                guard movable.count > 1 else { continue }
                await setTopic(topic, source: .automatic, for: movable)
                logTopic("created", topic: topic, count: movable.count)
                applied = true
            }
        }
        return applied
    }

    /// The pull requests of `task` changed: a stack may have formed. Deterministic links only.
    func attributeTopicsAfterPullRequests(of task: TaskState) {
        guard !task.isArchived else { return }
        Task { [weak self] in await self?.attributeTopics(in: task.scopeID) }
    }

    private func movableTasks(_ ids: [String]) -> [TaskID] {
        ids.compactMap { id in tasks.first { $0.id.rawValue == id && !$0.isArchived && !$0.record.topicIsExplicit }?.id }
    }

    /// The assistant's name for the subject `tasks` share, else the words their names and branches have in common.
    private func topicName(for tasks: [TaskState]) async -> String? {
        let ordered = tasks.sorted { $0.record.createdAt < $1.record.createdAt }
        if let named = await assistTopicName(for: ordered) { return named }
        return TopicName.fallback(names: ordered.map(\.name), branches: ordered.map(\.record.branch))
    }

    /// Every topic the scope has used, archived tasks' included: a piece of work picked up again goes back under the
    /// name `scope summary` already reports it by.
    func knownTopics(in scope: ScopeID) -> [String] {
        let open = topics(in: scope)
        return open + TaskTopic.distinct(tasks.filter { $0.scopeID == scope && $0.isArchived }.map(\.record.topic))
            .filter { topic in !open.contains { TaskTopic.key($0) == TaskTopic.key(topic) } }
    }

    /// `scope topics regroup`: what `TopicAttribution.regroup` would do — or, with `apply`, does — to the open tasks
    /// of `scope` (every scope with `nil`), topics given before Scope grouped tasks itself included. Names come from
    /// the tasks' shared words, never the assistant: a report has to be quick and say the same thing twice.
    func regroupTopics(in scope: ScopeID?, apply: Bool) async -> String {
        var lines: [String] = []
        for scopeState in scopes where scope == nil || scopeState.id == scope {
            let records = tasks.filter { $0.scopeID == scopeState.id }.map(\.record)
            let decisions = TopicAttribution.regroup(records)
            guard !decisions.isEmpty else { continue }
            lines.append("\(scopeState.name):")
            let names = Dictionary(records.map { ($0.id.rawValue, $0) }) { first, _ in first }
            for decision in decisions {
                switch decision {
                case .file(let ids, let topic):
                    let tasks = ids.compactMap { names[$0] }
                    lines.append("  file under “\(topic)”: " + tasks.map(\.slug).joined(separator: ", "))
                    if apply { await setTopic(topic, source: .automatic, for: tasks.map(\.id)) }
                case .create(let ids, _):
                    let tasks = ids.compactMap { names[$0] }.sorted { $0.createdAt < $1.createdAt }
                    let proposed = TopicName.fallback(names: tasks.map(\.name), branches: tasks.map(\.branch)) ?? tasks[0].slug
                    let topic = TopicName.reuse(proposed, among: knownTopics(in: scopeState.id))
                    lines.append("  new topic “\(topic)”: " + tasks.map(\.slug).joined(separator: ", "))
                    if apply { await setTopic(topic, source: .automatic, for: tasks.map(\.id)) }
                }
            }
        }
        guard !lines.isEmpty else { return "nothing to regroup: linked tasks already share a topic" }
        lines.append(apply ? "done" : "dry run — run again with --apply to file them")
        return lines.joined(separator: "\n")
    }

    private func logTopic(_ outcome: String, topic: String, count: Int) {
        Log.app.notice("topic \(outcome, privacy: .public): \(topic, privacy: .public) (\(count) tasks)")
    }
}
