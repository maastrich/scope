import AppKit
import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Best-of-N (spec §4.3): one brief run as N sibling tasks, compared in one sheet, one kept.
///
/// The N tasks are ordinary tasks under one topic, each with `TaskRecord.attempt` saying which family it belongs
/// to; everything here is about the family — creating it, reading it as columns, diffing two of its members,
/// keeping one and archiving the rest.
@MainActor
extension AppModel {
    /// One family of attempts the Compare sheet can show: at least two of them still open.
    struct AttemptGroup: Identifiable, Equatable {
        let id: String
        let baseName: String
        let scopeID: ScopeID
        var count: Int
    }

    // MARK: Creating

    /// Creates the N tasks of `proposal` run `count` ways: `<title> · attempt i` on `<branch>-ai`, filed under a
    /// topic named after the title, each with its own model and driver when the lists say so. The attempts
    /// created before a failure stay — they are tasks, visible, and the error names the one that failed.
    @discardableResult
    func createAttempts(
        _ proposal: TaskProposal, prompt: String, count: Int, models: [String], drivers: [String], driverID: String?,
        in scopeID: ScopeID, repos: [String], startPoint: TaskStartPoint = .defaultBranch, openThread: Bool = true,
        runSetup: Bool = true, threadOrigin: ThreadOrigin = .user, createdBy: String? = nil, parentTask: TaskID? = nil,
        deliverable: String? = nil, issue: Issue? = nil, model: String? = nil
    ) async throws -> [TaskState] {
        let plans: [TaskAttempts.Plan]
        switch TaskAttempts.plan(count: count, name: proposal.title, slug: proposal.slug, branch: proposal.branch,
                                 models: models, drivers: drivers) {
        case .failure(let refusal): throw TaskError.persistence(refusal.message)
        case .success(let planned): plans = planned
        }
        let group = UUID().uuidString
        let topic = TaskAttempts.topic(for: proposal.title)
        var created: [TaskState] = []
        for plan in plans {
            let attempt = TaskAttempt(group: group, index: plan.index, count: count, baseName: proposal.title,
                                      baseBranch: proposal.branch, model: plan.model ?? model, driver: plan.driver ?? driverID)
            let each = TaskProposal(title: plan.name, slug: uniqueTaskSlug(slugify(plan.slug), in: scopeID),
                                    branch: plan.branch, repos: proposal.repos, source: proposal.source)
            do {
                created.append(try await createTask(
                    each, prompt: prompt, driverID: plan.driver ?? driverID, in: scopeID, repos: repos, startPoint: startPoint,
                    openThread: openThread, runSetup: runSetup, threadOrigin: threadOrigin, createdBy: createdBy,
                    topic: topic, parentTask: parentTask, deliverable: deliverable, model: plan.model ?? model,
                    issue: issue, attempt: attempt
                ))
            } catch {
                throw TaskError.persistence("attempt \(plan.index) of \(count) could not be created (\(created.count) were): \(error)")
            }
        }
        Usage.click("task.attempts", label: "Create several attempts of a brief")
        return created
    }

    // MARK: Reading the family

    /// The attempts of `group`, by index; archived ones included, since a comparison outlives an archive.
    func attempts(inGroup group: String) -> [TaskState] {
        tasks.filter { $0.record.attempt?.group == group }
            .sorted { ($0.record.attempt?.index ?? 0) < ($1.record.attempt?.index ?? 0) }
    }

    /// The families of `scope` with at least two attempts still open — what the palette and the topic row offer.
    func attemptGroups(in scope: ScopeID) -> [AttemptGroup] {
        var seen: [String: AttemptGroup] = [:]
        var order: [String] = []
        for task in tasks where task.scopeID == scope && !task.isArchived {
            guard let attempt = task.record.attempt else { continue }
            if seen[attempt.group] == nil {
                order.append(attempt.group)
                seen[attempt.group] = AttemptGroup(id: attempt.group, baseName: attempt.baseName, scopeID: scope, count: 0)
            }
            seen[attempt.group]?.count += 1
        }
        return order.compactMap { seen[$0] }.filter { $0.count >= 2 }
    }

    /// The family `tasks` (a topic's members) belong to, when they are one family: what the topic row's menu offers.
    func attemptGroup(among tasks: [TaskState]) -> AttemptGroup? {
        let groups = Set(tasks.compactMap { $0.record.attempt?.group })
        guard groups.count == 1, let group = groups.first, let scope = tasks.first?.scopeID else { return nil }
        return attemptGroups(in: scope).first { $0.id == group }
    }

    /// Opens the Compare sheet on `group`.
    func presentCompare(group: String) {
        Usage.click("task.compare-attempts", label: "Compare the attempts of a brief")
        attemptsCompared = group
        globalSheet = .compareAttempts
    }

    /// One column per attempt: what each one did, as far as Scope can tell without reading the code.
    func attemptColumns(for group: String) -> [TaskAttempts.Column] {
        attempts(inGroup: group).map { task in
            let threads = threads(in: task.id)
            let first = threads.first
            let seconds = threads.reduce(0.0) { $0 + $1.activity.turns.reduce(0.0) { $0 + $1.duration } }
            let tokens = tokenUsage.snapshot.tasks[task.id.rawValue]?.total.total
            let reply = threads.compactMap(\.lastReply).max { $0.at < $1.at }?.text
            let kept = task.isArchived ? deliverable(of: task)?.markdown : nil
            let excerpt = TaskAttempts.excerpt(attemptReport(of: task) ?? kept ?? reply)
            let status = task.isArchived ? "Archived" : TaskStatus.resolve(taskFacts(for: task)).label
            return TaskAttempts.Column(
                id: task.id.rawValue, index: task.record.attempt?.index ?? 0, name: task.name, branch: task.branch,
                model: first?.record.model ?? task.record.attempt?.model,
                driver: profile(id: first?.record.driverID ?? task.record.attempt?.driver)?.name,
                status: status, tokens: (tokens ?? 0) > 0 ? tokens : nil, agentSeconds: seconds,
                filesChanged: task.record.activeRepos.reduce(0) { $0 + (task.summary(for: $1)?.files ?? 0) },
                additions: task.totalAdditions, deletions: task.totalDeletions,
                tests: TaskAttempts.testsRun(in: reply), excerpt: excerpt, isArchived: task.isArchived
            )
        }
    }

    /// The deliverable file of an open attempt (`REPORT.md`, or the record's `deliverable`), read off the sandbox.
    private func attemptReport(of task: TaskState) -> String? {
        guard !task.isArchived else { return nil }
        let roots = [task.record.rootURL] + task.record.activeRepos.map(\.sandboxURL)
        let names = [task.record.deliverable, "REPORT.md"].compactMap { $0 }
        for root in roots {
            for name in names where AttemptFileCopy.isSafe(name) {
                let url = root.appending(path: name)
                if let data = try? Data(contentsOf: url), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) {
                    return text
                }
            }
        }
        return nil
    }

    // MARK: Diff

    /// The diff pane's files: `left` against `right`, two attempts' branches as committed; or `left` against the
    /// base — its task delta, uncommitted work included — when `right` is `nil`. Per repository of the task.
    func attemptDiff(left: TaskState, right: TaskState?, repo: TaskRepo) async -> Result<[DiffFile], AttemptDiffError> {
        guard let repoURL = left.record.activeRepos.first(where: { $0.id == repo.id }).map(\.sandboxURL) else {
            return .failure(AttemptDiffError("\(repo.name) is no longer part of \(left.name)"))
        }
        // The base's client, as the task delta does: one serial queue per repository, sandboxes included.
        let client = await env.git.client(for: left.baseURL(for: repo))
        do {
            if let right {
                guard let other = right.record.repos.first(where: { $0.id == repo.id }) else {
                    return .failure(AttemptDiffError("\(right.name) has no sandbox for \(repo.name)"))
                }
                // Two attempts of one brief fork the same repository: both branches live in either worktree.
                return .success(try await Delta.compare(from: right.branch(in: other), to: left.branch(in: repo),
                                                        in: repoURL, using: client))
            }
            return .success(try await Delta.load(mode: .task, in: repoURL, using: client).files)
        } catch {
            return .failure(AttemptDiffError(String(describing: error)))
        }
    }

    /// Why the diff pane has nothing to show, in words.
    struct AttemptDiffError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Keeping one

    /// *Keep this one*: the chosen attempt takes the brief's name and branch back, the others are archived (branches
    /// kept, deliverables kept, as any archive does), and the Inbox says so once. One action, no question: the
    /// others are a restore away.
    func keepAttempt(_ task: TaskState) async {
        guard let attempt = task.record.attempt else { return }
        let siblings = attempts(inGroup: attempt.group).filter { $0.id != task.id && !$0.isArchived }
        Usage.click("task.keep-attempt", label: "Keep one attempt, archive the others")
        do {
            let record = try await env.tasks.keepAttempt(task.id, otherBranches: siblings.map(\.branch))
            task.update(record: record)
            if let scope = scope(task.scopeID) {
                let summaries = await graphSummaries(for: scope)
                try? await env.tasks.regenerateProjection(task.id, scopeContext: scope.declaration.context,
                                                          scopeRepos: scope.repos.map(\.id), repoSummaries: summaries,
                                                          contextFiles: contextFileNames)
                scope.refreshFacts()
            }
            task.refresh()
        } catch {
            problems.error("Could not keep \(task.name)", detail: String(describing: error), scope: task.scopeID)
            return
        }
        if attemptsCompared == attempt.group { globalSheet = nil }
        for sibling in siblings {
            await archiveTask(sibling.id)
        }
        selection = .task(task.id)
    }

    // MARK: Cherry-picking a file

    /// Brings `path` of `repo` from `source` into `target`, file for file: the target is checkpointed first, so what
    /// the copy overwrites is a restore away, then the file is copied, or removed when the source no longer has it. The target's delta refreshes on its own through its watcher.
    func copyAttemptFile(_ path: String, repo: TaskRepo, from source: TaskState, to target: TaskState) async {
        guard let from = source.record.repos.first(where: { $0.id == repo.id })?.sandboxURL,
              let to = target.record.activeRepos.first(where: { $0.id == repo.id })?.sandboxURL else { return }
        Usage.click("task.copy-attempt-file", label: "Copy a file from one attempt into another")
        do {
            try await env.tasks.checkpoints.snapshot(target.record, turn: nil, reason: .beforeCopy)
            _ = try AttemptFileCopy.copy(path, from: from, to: to)
            target.refresh()
        } catch {
            problems.error("Could not copy \(path) into \(target.name)", detail: String(describing: error), scope: target.scopeID)
        }
    }
}

private extension TaskState {
    /// The branch a repository of this task is on, which is the task's unless the sandbox says otherwise.
    func branch(in repo: TaskRepo) -> String {
        repo.branch.isEmpty ? branch : repo.branch
    }
}
