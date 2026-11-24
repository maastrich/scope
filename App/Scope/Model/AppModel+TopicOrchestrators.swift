import Foundation
import ScopeAssist
import ScopeCore
import ScopeGit
import ScopeTasks

/// One orchestrator thread per topic, opened on demand (`TopicOrchestration`): an ordinary agent thread at the scope
/// root whose record names the topic, filed under the topic's row, told about the topic's milestones through the
/// acting triggers' gate, and put away by Scope once the topic has no open task left and the user is done with it
/// (`TopicOrchestration.hold`). A closed one is kept (`RetiredOrchestrators`): opening it again resumes it.
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

    /// The same topics by name: one whose tasks are all gone still gets a row for its orchestrator
    /// (`TaskTopic.entries`).
    func orchestratedTopicNames(in scope: ScopeID) -> [String] {
        topicOrchestrators(in: scope).compactMap(\.record.topic)
    }

    /// The topic row's *Open Orchestrator*: selects the topic's orchestrator, starting it when it is stopped, brings
    /// back the one that was closed with its conversation (`RetiredOrchestrators`), or creates it with the topic's
    /// tasks in its opening prompt. The driver is the scope orchestrator's (Settings ▸ General ▸
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
        if let resumed = await resumeRetiredOrchestrator(topic, in: scopeID) { return resumed }
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

    /// The topic changed name: its orchestrator follows, title included — the closed one too.
    func renameTopicOrchestrator(_ topic: String, to newName: String, in scope: ScopeID) {
        updateRetiredOrchestrators { $0.rename(topic: topic, to: newName, title: TopicOrchestration.title(for: newName), scope: scope) }
        guard let session = topicOrchestrator(topic, in: scope) else { return }
        session.setTopic(newName, title: TopicOrchestration.title(for: newName))
        let record = session.record
        Task { await env.threadRecords.save(record) }
    }

    // MARK: Putting away, and back

    /// Puts away the orchestrators whose topic has no open task left — archived, closed, or filed elsewhere — once
    /// the user is done with them (`TopicOrchestration.hold`): never one at work, waiting on an answer, with an
    /// unread report, on screen, or touched in the last half hour. Looked at again when a task goes, when a turn of
    /// the orchestrator ends, and every `orchestratorSweepInterval`, so one that was held gets its turn later.
    /// Nothing is lost: `close` keeps its record, and opening the topic's orchestrator again resumes it.
    func closeIdleTopicOrchestrators(in scope: ScopeID, now: Date = .now) async {
        for session in topicOrchestrators(in: scope) {
            guard let topic = session.record.topic else { continue }
            let waiting = if case .waiting = session.displayState { true } else { false }
            let record = session.record
            let lastActivity = [session.lastHumanInputAt, session.activity.turns.last?.endedAt, record.lastLaunchedAt, record.createdAt]
                .compactMap { $0 }.max() ?? record.createdAt
            let standing = TopicOrchestration.Standing(
                openTasks: tasks(inTopic: topic, scope: scope).count, working: session.isWorking, waitingOnUser: waiting,
                pendingMessages: !(pendingDeliveries[session.id] ?? []).isEmpty,
                unread: session.displayState.isUnreadResult, watched: selectedThreadID == session.id,
                lastActivity: lastActivity)
            // The notices a merge brought are told first, whatever holds the thread open: they are its last report.
            guard standing.openTasks == 0, !standing.working, !standing.waitingOnUser, !standing.pendingMessages,
                  !noticeTopicMilestones(topic, in: scope) else { continue }
            guard TopicOrchestration.hold(standing, now: now) == nil else { continue }
            Log.app.notice("closing the orchestrator of \(topic, privacy: .public): no open task left, quiet since \(lastActivity, privacy: .public)")
            await close(session.id, force: true, by: .automatic("topic “\(topic)” has no open task left"))
        }
    }

    static let orchestratorSweepInterval: Duration = .seconds(10 * 60)

    /// The periodic look: an orchestrator held at the last archive (unread, waiting, just used) has nothing else to
    /// bring it back up once its topic is empty.
    func startTopicOrchestratorSweep() {
        topicOrchestratorSweep?.cancel()
        topicOrchestratorSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.orchestratorSweepInterval)
                guard !Task.isCancelled, let self else { return }
                for scope in Set(self.threads.filter { $0.placement.topicKey != nil }.map(\.record.scopeID)) {
                    await self.closeIdleTopicOrchestrators(in: scope)
                }
            }
        }
    }

    /// A closed orchestrator keeps its record, so its conversation can be resumed (`close`).
    func retireOrchestrator(_ record: ThreadRecord) {
        updateRetiredOrchestrators { $0.keep(record) }
    }

    /// The orchestrator is open again (Undo): nothing left to bring back.
    func forgetRetiredOrchestrator(_ record: ThreadRecord) {
        guard let topic = record.topic else { return }
        updateRetiredOrchestrators { $0.remove(topic: topic, scope: record.scopeID) }
    }

    /// The topics of `scope` whose closed orchestrator can be brought back (the palette's *Reopen Orchestrator*).
    func retiredOrchestratorTopics(in scope: ScopeID) -> [String] {
        RetiredOrchestrators.load(home: env.home).records.reversed()
            .filter { $0.scopeID == scope && session($0.id) == nil }.compactMap(\.topic)
            .filter { topicOrchestrator($0, in: scope) == nil }
    }

    /// Read, changed and written back in one go: the list is small and changes at a close or a reopen only.
    private func updateRetiredOrchestrators(_ change: (inout RetiredOrchestrators) -> Void) {
        let before = RetiredOrchestrators.load(home: env.home)
        var after = before
        change(&after)
        guard after != before else { return }
        do {
            try after.save(home: env.home)
        } catch {
            Log.app.error("closed orchestrators not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The closed orchestrator of `topic`, back in its row and resuming its driver session. `nil` when there is none,
    /// or when its driver is gone — a fresh one then starts.
    private func resumeRetiredOrchestrator(_ topic: String, in scopeID: ScopeID) async -> ThreadSession? {
        guard scope(scopeID) != nil,
              let record = RetiredOrchestrators.load(home: env.home).record(topic: topic, scope: scopeID),
              session(record.id) == nil, let profile = profile(id: record.driverID), profile.canResume else { return nil }
        forgetRetiredOrchestrator(record)
        forgetUndo(id: "thread:\(record.id.rawValue)")
        let session = ThreadSession(record: record, profile: profile)
        register(session)
        await env.threadRecords.save(record)
        selection = .thread(session.id)
        selectedThreadID = session.id
        Log.app.notice("resuming the orchestrator of \(topic, privacy: .public)")
        await launch(session, mode: .relaunch(profile: profile, resumeID: record.resumeID))
        return session
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
