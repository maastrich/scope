import Foundation
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
        for repo in task.activeRepos {
            let base = task.baseURL(for: repo)
            let sandbox = repo.sandboxURL
            guard FileManager.default.fileExists(atPath: sandbox.path) else { continue }
            let lag = await Task.detached(priority: .utility) { () -> BranchLag? in
                let client = await git.client(for: base)
                return try? await client.branchLag(at: sandbox)
            }.value
            if let lag { repos[repo.repoRelativePath] = lag }
        }
        guard !task.isArchived else { return nil }
        let lag = repos.isEmpty ? nil : TaskLag(repos: repos)
        pullRequests.setTaskLag(lag, for: task.id)
        return lag
    }

    /// What `FollowMain.decide` reads for the task right now.
    func followMainFacts(for task: TaskState, lag: TaskLag?) -> FollowMain.Facts {
        let live = livePullRequest(for: task)
        let state = live?.state.rawValue ?? task.record.pullRequest?.state
        let settled = state == "merged" || state == "closed"
        return FollowMain.Facts(
            lag: lag, pullRequestMergeable: live?.state == .open ? live?.mergeable : nil, pullRequestSettled: settled,
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
        case .rebase:
            guard let lag else { return "nothing to do for \(task.record.slug): the lag could not be measured" }
            return await rebaseSandboxes(of: task, lag: lag)
        }
    }

    /// Tells the task's thread that main moved — the first live Claude Code or Codex thread, or a new one when none
    /// runs — through the same delivery as a review or a failed check: now between turns, at the end of the turn
    /// otherwise. Remembered against the head of main, so the same move is never asked twice.
    private func askAgentToFollowMain(_ task: TaskState, lag: TaskLag) async -> String {
        let fromGitHub = livePullRequest(for: task)?.mergeable == .conflicting
        let text = FollowMainPrompts.envelope(FollowMainPrompts.mainMoved(lag: lag, conflictsFromGitHub: fromGitHub))
        await noteFollowedMain(task, head: lag.upstreamHead)
        if let thread = threads(in: task.id).first(where: { $0.isAlive && $0.deliversEvents }) {
            switch deliver(text, to: thread.id, label: "main moved") {
            case .sent:
                return "asked \(displayTitle(for: thread)) to rebase \(task.branch) on \(lag.upstream)"
            case .queued:
                return "will ask \(displayTitle(for: thread)) to rebase \(task.branch) once its turn ends"
            case .failed(let reason):
                problems.warn("Could not ask \(task.name) to rebase", detail: reason, scope: task.scopeID)
                return "could not reach the thread of \(task.record.slug): \(reason)"
            }
        }
        // No agent in the task: one is started with the message as its first prompt, with the default driver, as
        // long as it reports its turns (a shell cannot be asked anything).
        let driver = [defaultProfile].compactMap { $0 }.first(where: AdapterInstaller.deliversEvents)
            ?? drivers.profiles.first(where: AdapterInstaller.deliversEvents)
        guard let driver else {
            problems.warn("No agent to ask about \(task.name)'s branch", detail: "main moved; no Claude Code or Codex profile is installed.",
                          scope: task.scopeID)
            return "no agent profile to ask for \(task.record.slug)"
        }
        let origin = ThreadOrigin(author: .control, client: "scope")
        guard let session = await newThread(in: task.scopeID, driverID: driver.id, taskID: task.id, initialPrompt: text, origin: origin) else {
            return "could not open a thread in \(task.record.slug)"
        }
        return "opened \(displayTitle(for: session)) in \(task.record.slug) and asked it to rebase \(task.branch) on \(lag.upstream)"
    }

    /// `git rebase origin/<default>` in each sandbox that is behind, then a push with lease when the branch is
    /// published and its pull request open. A rebase that stops is aborted by `GitClient.rebase`, the branch left
    /// as it was, and the agent asked instead.
    private func rebaseSandboxes(of task: TaskState, lag: TaskLag) async -> String {
        let git = env.git
        let pullRequestOpen = livePullRequest(for: task)?.state == .open
        var done: [String] = []
        var pushed = false
        var conflicted = lag
        var stopped = false
        for repo in task.activeRepos {
            guard let repoLag = lag.repos[repo.repoRelativePath], repoLag.isBehind else { continue }
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
                done.append(repo.name)
                pushed = pushed || didPush
            case .success((.upToDate, _)):
                continue
            case .success((.dirty, _)):
                problems.warn("\(task.name) was not rebased", detail: "\(repo.name) has uncommitted changes.", scope: task.scopeID)
                stopped = true
            case .success((.conflicted(let paths), _)):
                conflicted.repos[repo.repoRelativePath]?.conflicts = paths
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
            return "rebase of \(task.record.slug) stopped on conflicts; " + (await askAgentToFollowMain(task, lag: conflicted))
        }
        await noteFollowedMain(task, head: lag.upstreamHead)
        await measureLag(of: task)
        guard !done.isEmpty else { return "nothing to rebase in \(task.record.slug)" }
        let what = done.count == 1 && task.record.isMonoRepo ? task.branch : done.joined(separator: ", ")
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
