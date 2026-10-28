import Foundation
import ScopeAssist
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks

/// A task follows main on its own (spec §4.3). After every background pull request refresh the task's sandboxes are
/// fetched and measured against `origin/<default>` — behind by how much, conflicts or not — and, per Settings ▸ Tasks
/// ▸ When main moves, Scope either tells the task's thread to rebase, rebases the sandbox itself when that is safe,
/// or only shows the lag. `FollowMain.decide` holds the rules; this runs git and types the message.
///
/// Nothing here touches a base checkout: every command runs in the task's sandbox, through the base's serial client.
extension AppModel {
    /// The mode in force for a task: its scope's override, else the preference.
    func followMainMode(for task: TaskState) -> FollowMainMode {
        scope(task.scopeID)?.declaration.followMain ?? config.preferences.followMain
    }

    /// The lag of a task as last measured, for the views.
    func lag(of task: TaskState) -> TaskLag? { pullRequests.taskLags[task.id] }

    /// Fetches and measures every active sandbox of the task. `nil` when none could be measured.
    @discardableResult
    func measureLag(of task: TaskState) async -> TaskLag? {
        guard !task.isArchived else { return nil }
        let git = env.git
        var repos: [String: BranchLag] = [:]
        // Every worktree, each measured on its own branch, keyed by `TaskRepo.sandboxKey`.
        for repo in task.activeSandboxes {
            let base = task.baseURL(for: repo)
            let sandbox = repo.sandboxURL
            guard FileManager.default.fileExists(atPath: sandbox.path) else { continue }
            let lag = await Task.detached(priority: .utility) { () -> BranchLag? in
                let client = await git.client(for: base)
                return try? await client.branchLag(at: sandbox)
            }.value
            if let lag { repos[repo.sandboxKey] = lag }
        }
        guard !task.isArchived else { return nil }
        let lag = repos.isEmpty ? nil : TaskLag(repos: repos)
        pullRequests.setTaskLag(lag, for: task.id)
        return lag
    }

    /// What `FollowMain.decide` reads for the task right now.
    func followMainFacts(for task: TaskState, lag: TaskLag?) -> FollowMain.Facts {
        // Several pull requests: any open one that conflicts is a conflict; settled only once every one is.
        let states = pullRequestStates(for: task)
        let open = states.compactMap { $0.live }.filter { $0.state == .open }
        let mergeable: PullRequest.Mergeable? = open.isEmpty ? nil : (open.contains { $0.mergeable == .conflicting } ? .conflicting : open[0].mergeable)
        let settled = PullRequestSet.isSettled(states.map { $0.live?.state.rawValue ?? $0.link.state })
        return FollowMain.Facts(
            lag: lag, pullRequestMergeable: mergeable, pullRequestSettled: settled,
            holdBranch: task.record.holdBranch,
            threadRunning: threads(in: task.id).contains { $0.isAlive && $0.displayState == .running },
            actedOnHead: task.record.followedMainHead)
    }

    /// The background pass, after the task's pull request was refreshed.
    func followMain(_ task: TaskState) async {
        guard !task.isArchived, !pullRequests.followingMain.contains(task.id) else { return }
        pullRequests.setFollowingMain(task.id, true)
        defer { pullRequests.setFollowingMain(task.id, false) }
        let lag = await measureLag(of: task)
        let decision = FollowMain.decide(followMainFacts(for: task, lag: lag), mode: followMainMode(for: task))
        _ = await act(on: decision, task: task, lag: lag)
    }

    /// `scope task rebase` and the context menu: the preference and the once-per-head memory step aside, the hold
    /// does not. Answers with one sentence saying what was done, or why nothing was.
    func rebaseNow(_ task: TaskState) async -> String {
        guard !task.isArchived else { return "\(task.record.slug) is archived" }
        guard !pullRequests.followingMain.contains(task.id) else { return "Scope is already at work on \(task.record.slug)'s branch" }
        pullRequests.setFollowingMain(task.id, true)
        defer { pullRequests.setFollowingMain(task.id, false) }
        let lag = await measureLag(of: task)
        let decision = FollowMain.decide(followMainFacts(for: task, lag: lag), mode: followMainMode(for: task), onDemand: true)
        return await act(on: decision, task: task, lag: lag)
    }

    /// The context menu's hold: "Don't rebase automatically".
    func setHoldBranch(_ hold: Bool, for task: TaskState) async {
        do {
            let record = try await env.tasks.setHoldBranch(hold, for: task.id)
            task.update(record: record)
        } catch {
            problems.warn("Could not mark the branch of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    // MARK: Acting

    private func act(on decision: FollowMain, task: TaskState, lag: TaskLag?) async -> String {
        switch decision {
        case .leave(let why):
            return "nothing to do for \(task.record.slug): \(why)"
        case .askAgent:
            return await askAgentToFollowMain(task, lag: lag ?? TaskLag())
        case .askAgentPreventive:
            return await askAgentToFollowMain(task, lag: lag ?? TaskLag(), preventive: true)
        case .rebase:
            guard let lag else { return "nothing to do for \(task.record.slug): the lag could not be measured" }
            return await rebaseSandboxes(of: task, lag: lag)
        }
    }

    /// Tells the task's thread that main moved — conflicts (`ActingTrigger.conflicts`), or main touching the task's
    /// files before it conflicts (`.baseMoved`) — through the acting triggers' gate: once per head of main, never
    /// mid-turn or while the user types, under the trigger's hourly cap. A held message is not remembered against the
    /// head, so the next pass asks again. With no agent in the task, the user is notified instead. The message merges
    /// main in rather than rebasing: a thread's permissions refuse force pushes.
    private func askAgentToFollowMain(_ task: TaskState, lag: TaskLag, preventive: Bool = false,
                                      rebaseStopped: Bool = false) async -> String {
        let open = pullRequestStates(for: task).compactMap(\.live).filter { $0.state == .open }
        let trigger: ActingTrigger = preventive ? .baseMoved : .conflicts
        let base = lag.upstream.split(separator: "/", maxSplits: 1).last.map(String.init) ?? lag.upstream
        let number = open.first?.number
        let text = preventive
            ? ActingPrompts.baseMoved(base: base, branch: task.branch, files: lag.overlappingPaths, pullRequest: number)
            : ActingPrompts.conflicts(pullRequest: number, base: base, branch: task.branch, paths: lag.conflictedPaths,
                                      rebaseStopped: rebaseStopped)
        guard preference(trigger).enabled else { return "nothing to do for \(task.record.slug): \(trigger.title) is off" }
        if let thread = actingThread(in: task.id) {
            let heads = open.compactMap(\.headRefOid).sorted().joined(separator: ",")
            let key = preventive ? "base@\(lag.upstreamHead)" : "conflict@\(lag.upstreamHead)@\(heads)"
            let verdict = fire(ActingTriggers.Proposal(trigger: trigger, thread: thread.id, key: key, action: .send(text),
                                                       cause: rebaseStopped ? "rebase-stopped" : (preventive ? "overlap" : "conflicting")))
            switch verdict {
            case .act:
                await noteFollowedMain(task, head: lag.upstreamHead)
                return "asked \(displayTitle(for: thread)) to bring \(lag.upstream) into \(task.branch)"
            case .hold(let why):
                return "will ask \(displayTitle(for: thread)) about \(lag.upstream) once it is free (\(why))"
            case .skip(let why):
                await noteFollowedMain(task, head: lag.upstreamHead)
                return "nothing to do for \(task.record.slug): \(why)"
            case .capped:
                await noteFollowedMain(task, head: lag.upstreamHead)
                return "\(trigger.title) reached its hourly cap on \(displayTitle(for: thread)); the user is told"
            }
        }
        // No agent left in the task to ask: the user is told, once per head of main. A preventive update is not
        // worth even that.
        guard !preventive else { return "nothing to do for \(task.record.slug): no agent thread to ask" }
        await noteFollowedMain(task, head: lag.upstreamHead)
        let paths = lag.conflictedPaths
        notifyNoThread(trigger, task: task, key: "conflict@\(lag.upstreamHead)",
                       notice: "\(task.branch) conflicts with \(lag.upstream)" + (paths.isEmpty ? "" : " in " + paths.prefix(3).joined(separator: ", ")))
        return "no agent thread in \(task.record.slug) to ask about the conflicts; the user is told"
    }

    /// `git rebase origin/<default>` in each sandbox that is behind, then a push with lease when the branch is
    /// published and its pull request open. A rebase that stops is aborted by `GitClient.rebase`, the branch left
    /// as it was, and the agent asked instead.
    private func rebaseSandboxes(of task: TaskState, lag: TaskLag) async -> String {
        let git = env.git
        let pullRequestOpen = pullRequestState(for: task) == "open"
        var done: [String] = []
        var pushed = false
        var conflicted = lag
        var stopped = false
        for repo in task.activeSandboxes {
            guard let repoLag = lag.repos[repo.sandboxKey], repoLag.isBehind else { continue }
            let base = task.baseURL(for: repo)
            let sandbox = repo.sandboxURL
            let branch = repo.branch
            let upstream = repoLag.upstream
            let result = await Task.detached(priority: .utility) { () -> Result<(RebaseOutcome, Bool), any Error> in
                do {
                    let client = await git.client(for: base)
                    let outcome = try await client.rebase(at: sandbox, onto: upstream)
                    var pushed = false
                    if case .rebased = outcome, pullRequestOpen, await client.isPublished(branch, at: sandbox) {
                        try await client.pushWithLease(branch, at: sandbox)
                        pushed = true
                    }
                    return .success((outcome, pushed))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success((.rebased, let didPush)):
                done.append(repo.isSecondary ? repo.sandboxLabel(scopeName: task.record.scopeName) : repo.name)
                pushed = pushed || didPush
            case .success((.upToDate, _)):
                continue
            case .success((.dirty, _)):
                problems.warn("\(task.name) was not rebased", detail: "\(repo.sandboxLabel(scopeName: task.record.scopeName)) has uncommitted changes.", scope: task.scopeID)
                stopped = true
            case .success((.conflicted(let paths), _)):
                conflicted.repos[repo.sandboxKey]?.conflicts = paths
                stopped = true
            case .failure(let error):
                problems.warn("Could not rebase \(task.name) on \(upstream)", detail: String(describing: error), scope: task.scopeID)
                stopped = true
            }
            if stopped { break }
        }
        task.refresh()
        if conflicted.hasConflicts {
            // The rebase said what the dry merge did not: hand it to the agent with the paths.
            return "rebase of \(task.record.slug) stopped on conflicts; " + (await askAgentToFollowMain(task, lag: conflicted, rebaseStopped: true))
        }
        await noteFollowedMain(task, head: lag.upstreamHead)
        await measureLag(of: task)
        guard !done.isEmpty else { return "nothing to rebase in \(task.record.slug)" }
        let what = done.count == 1 && task.record.isMonoRepo && !task.record.hasSecondaryWorktrees ? task.branch : done.joined(separator: ", ")
        let line = "rebased \(what) on \(lag.upstream) (\(lag.behind) commit\(lag.behind == 1 ? "" : "s"))" + (pushed ? " and pushed with lease" : "")
        problems.report(Problem(severity: .info, title: "Rebased \(task.name) on \(lag.upstream)", detail: line, scopeID: task.scopeID))
        return line
    }

    private func noteFollowedMain(_ task: TaskState, head: String) async {
        guard !head.isEmpty else { return }
        do {
            let record = try await env.tasks.noteFollowedMain(head: head, for: task.id)
            task.update(record: record)
        } catch {
            // The record will say so next time; a lost note means one extra message, never a lost branch.
            Log.app.warning("could not note the head of main for \(task.record.slug, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
