import Foundation
import ScopeAssist
import ScopeCore
import ScopeGit
import ScopeTasks

/// One orchestrator thread per topic, opened on demand (`TopicOrchestration`): an ordinary agent thread at the scope
/// root whose record names the topic, filed under the topic's row, told about the topic's milestones through the
/// acting triggers' gate, and closed by Scope once the topic has no open task left.
extension AppModel {
    /// The orchestrator of `topic` in `scope`, whatever the topic's spelling.
    func topicOrchestrator(_ topic: String, in scope: ScopeID) -> ThreadSession? {
        let key = TaskTopic.key(topic)
        return threads.first { $0.placement.scopeID == scope && $0.placement.topicKey == key }
    }

    /// Every orchestrator thread of `scope`.
    func topicOrchestrators(in scope: ScopeID) -> [ThreadSession] {
        threads.filter { $0.placement.scopeID == scope && $0.placement.topicKey != nil }
    }

    /// The topics of `scope` that have an orchestrator, by `TaskTopic.key`: their row stays even with one task.
    func orchestratedTopics(in scope: ScopeID) -> Set<String> {
        Set(topicOrchestrators(in: scope).compactMap(\.placement.topicKey))
    }

    /// The topic row's *Open Orchestrator*: selects the topic's orchestrator, starting it when it is stopped, or creates
    /// it with the topic's tasks in its opening prompt. The driver is the scope orchestrator's (Settings ▸ General ▸
    /// Threads ▸ Orchestrator driver).
    @discardableResult
    func openTopicOrchestrator(_ topic: String, in scopeID: ScopeID) async -> ThreadSession? {
        if let existing = topicOrchestrator(topic, in: scopeID) {
            selection = .thread(existing.id)
            selectedThreadID = existing.id
            let launching = if case .launching = existing.phase { true } else { false }
            if !existing.isAlive, !launching {
                await launch(existing, mode: .relaunch(profile: existing.profile, resumeID: existing.record.resumeID))
            }
            return existing
        }
        guard let scope = scope(scopeID), let profile = residentProfile(for: .orchestrator) else {
            problems.error("No agent to orchestrate “\(topic)”", detail: "Install a driver profile that runs an agent.", scope: scopeID)
            return nil
        }
        let name = tasks(inTopic: topic, scope: scopeID).first?.record.topic ?? topic
        let brief = TopicOrchestration.brief(topic: name, scope: scope.name, tasks: topicFacts(name, in: scopeID))
        return await newThread(in: scopeID, driverID: profile.id, title: TopicOrchestration.title(for: name),
                               initialPrompt: brief, origin: .user, topic: name)
    }

    /// The topic's tasks as its orchestrator reads them, archived ones included.
    func topicFacts(_ topic: String, in scope: ScopeID) -> [TopicOrchestration.TaskFacts] {
        let key = TaskTopic.key(topic)
        return tasks.filter { $0.scopeID == scope && $0.record.topic.map(TaskTopic.key) == key }.map { task in
            let status = TaskStatus.resolve(taskFacts(for: task))
            let links = task.record.pullRequests.map { link -> String in
                var text = "\(link.repo.map { "\($0)" } ?? "")\(link.label) \(link.state ?? "open")"
                if link.isOpen, let live = self.pullRequests.taskPullRequest(link.url, for: task.id), live.checks != .none {
                    text += ", checks \(live.checks.rawValue)"
                }
                if let base = link.baseRefName { text += ", on \(base)" }
                return text
            }
            return TopicOrchestration.TaskFacts(
                slug: task.record.slug, name: task.name, state: status.label.lowercased(), branch: task.record.branch,
                pullRequests: links, brief: task.record.prompt, threads: threads(in: task.id).map(\.id.rawValue),
                archived: task.isArchived)
        }
    }

    /// The topic changed name: its orchestrator follows, title included.
    func renameTopicOrchestrator(_ topic: String, to newName: String, in scope: ScopeID) {
        guard let session = topicOrchestrator(topic, in: scope) else { return }
        session.setTopic(newName, title: TopicOrchestration.title(for: newName))
        let record = session.record
        Task { await env.threadRecords.save(record) }
    }

    /// Closes the orchestrators whose topic has no open task left — archived, closed, or filed elsewhere. Nothing is
    /// lost: the tasks keep the topic for `scope summary`, and opening it again starts a fresh one. One at work or
    /// waiting on the user is left to finish — the last merge's notice may be what it is answering — and closed at the
    /// end of that turn (`actingSaw`).
    func closeIdleTopicOrchestrators(in scope: ScopeID) async {
        for session in topicOrchestrators(in: scope) {
            guard let topic = session.record.topic,
                  TopicOrchestration.shouldClose(openTasks: tasks(inTopic: topic, scope: scope).count) else { continue }
            let waiting = if case .waiting = session.displayState { true } else { false }
            guard !session.isWorking, !waiting, (pendingDeliveries[session.id] ?? []).isEmpty else { continue }
            // The last task went with its merge: the notices it brought are told first, and answered before it closes.
            guard !noticeTopicMilestones(topic, in: scope) else { continue }
            Log.app.notice("closing the orchestrator of \(topic, privacy: .public): no open task left")
            await close(session.id, force: true, by: .automatic("topic “\(topic)” has no open task left"))
        }
    }

    /// A refresh of `task`'s pull requests: what its topic's orchestrator, if one runs, should hear about.
    func noticeTopicMilestones(of task: TaskState) {
        guard let topic = task.record.topic else { return }
        noticeTopicMilestones(topic, in: task.scopeID)
    }

    /// The milestones of `topic` since its orchestrator opened, through the gate. Every task of the topic counts,
    /// archived ones too: a merged task is archived right after its merge, and a notice held meanwhile must still
    /// come. Returns whether one was sent.
    @discardableResult
    func noticeTopicMilestones(_ topic: String, in scope: ScopeID) -> Bool {
        guard let session = topicOrchestrator(topic, in: scope), session.isAlive else { return false }
        let key = TaskTopic.key(topic)
        let members = tasks.filter { $0.scopeID == scope && $0.record.topic.map(TaskTopic.key) == key }
            .map { TopicOrchestration.Member(task: $0.record.slug, pullRequests: $0.record.pullRequests, archived: $0.isArchived) }
        var acted = false
        for milestone in TopicOrchestration.milestones(members, since: session.record.createdAt) {
            let (cause, message) = switch milestone {
            case .merged(let slug, let number, _): ("merged", ActingPrompts.topicMerged(topic: topic, task: slug, pullRequest: number))
            case .delivered(let slugs): ("delivered", ActingPrompts.topicDelivered(topic: topic, tasks: slugs))
            }
            let verdict = fire(ActingTriggers.Proposal(trigger: .topic, thread: session.id, key: milestone.key,
                                                       action: .send(message), cause: cause))
            if case .act = verdict { acted = true }
        }
        return acted
    }
}
