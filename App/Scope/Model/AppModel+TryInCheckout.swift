import Foundation
import ScopeCore
import ScopeGit
import ScopeTasks

/// Why a try, a refresh or a put back did not happen, said to the user or the CLI.
enum TryInCheckoutFailure: Error, CustomStringConvertible {
    case notAllowed
    case archived
    case nothingToTry
    case alreadyTrying(repo: String, task: String)
    case notTrying
    case baseMissing(repo: String)

    var description: String {
        switch self {
        case .notAllowed: "trying a task in your checkout is off: Settings › Tasks › Allow trying a task in my checkout"
        case .archived: "the task is archived"
        case .nothingToTry: "the task has no active repository"
        case .alreadyTrying(let repo, let task): "your checkout of \(repo) is already on the task \(task); put it back first"
        case .notTrying: "your checkout is not on this task"
        case .baseMissing(let repo): "the base checkout of \(repo) is not there"
        }
    }
}

/// A task's branch run in the user's own checkout, then put back (spec §4.5). The one place Scope moves a base,
/// bent on purpose: opt-in per scope, and reversible by construction — `GitClient.beginTry` / `endTry` stash,
/// detach and switch back, never reset. The session is written on the task record before anything else, so a quit
/// or crash in the middle is finished at the next launch (`finishInterruptedPutBacks`). The task's threads keep
/// working in the sandbox the whole time: the base is a mirror the user runs, not a place anyone edits.
extension AppModel {
    /// Whether the task's scope allows it: the scope's own setting, else the preference. Off by default.
    func mayTryInCheckout(_ task: TaskState) -> Bool {
        scope(task.scopeID)?.declaration.allowTryInCheckout ?? config.preferences.allowTryInCheckout
    }

    /// Every task whose branch a base checkout is on right now.
    var tryingTasks: [TaskState] { tasks.filter { !$0.record.trying.isEmpty } }

    /// The task (and session) a base repository is on, if any: what the Base panel's banner shows.
    func trySession(of repo: RepoState, in scope: ScopeState) -> (task: TaskState, session: TrySession)? {
        let key = TaskRepo.normalize(GraphModel.key(for: repo))
        for task in tasks where task.scopeID == scope.id {
            if let session = task.record.trySession(for: key) { return (task, session) }
        }
        return nil
    }

    // MARK: Try

    /// Puts the base checkout of every repository of the task on the task's branch, detached, after stashing what was
    /// not committed. Refuses when a base is mid-rebase or already on another task; a repository that fails after
    /// others succeeded is reported and the others put back, so a task is either tried whole or not at all.
    @discardableResult
    func tryInCheckout(_ task: TaskState) async throws -> String {
        guard mayTryInCheckout(task) else { throw TryInCheckoutFailure.notAllowed }
        guard !task.isArchived else { throw TryInCheckoutFailure.archived }
        guard task.record.trying.isEmpty else {
            return "your checkout is already on \(task.record.slug) since \(task.record.trying[0].since.formatted(date: .omitted, time: .shortened))"
        }
        let repos = task.activeRepos
        guard !repos.isEmpty else { throw TryInCheckoutFailure.nothingToTry }
        for repo in repos {
            for other in tasks where other.scopeID == task.scopeID && other.id != task.id {
                if other.record.trySession(for: repo.repoRelativePath) != nil {
                    throw TryInCheckoutFailure.alreadyTrying(repo: repo.name, task: other.record.slug)
                }
            }
            guard RepoDiscovery.gitKind(at: task.baseURL(for: repo)) != nil else {
                throw TryInCheckoutFailure.baseMissing(repo: repo.name)
            }
        }
        let git = env.git
        let slug = task.record.slug
        var sessions: [TrySession] = []
        for repo in repos {
            let base = task.baseURL(for: repo)
            let branch = repo.branch
            let result = await Task.detached(priority: .userInitiated) { () -> Result<TryCheckout, any Error> in
                let client = await git.client(for: base)
                do { return .success(try await client.beginTry(branch: branch, label: GitClient.tryStashLabel(task: slug))) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success(let checkout):
                sessions.append(TrySession(repoRelativePath: repo.repoRelativePath, previousHead: checkout.previousHead,
                                           previousBranch: checkout.previousBranch, stashSHA: checkout.stashSHA, head: checkout.head))
                // Written as soon as the base moved: a crash now leaves a record that knows how to put it back.
                try await writeTrying(sessions, for: task)
            case .failure(let error):
                // Whole or nothing: the repositories already moved go back before the failure is reported.
                for done in sessions {
                    _ = await putBackRepo(done, of: task)
                }
                try? await writeTrying([], for: task)
                refreshBases(of: task)
                throw error
            }
        }
        refreshBases(of: task)
        let what = repos.count == 1 ? "your checkout" : "your \(repos.count) checkouts"
        return "\(what) now on \(task.branch) (detached); Put back restores \(sessions.map(\.previousLabel).joined(separator: ", "))"
    }

    /// Moves the detached base to the task branch's current head: the sandbox committed since.
    @discardableResult
    func refreshTry(_ task: TaskState) async throws -> String {
        guard !task.record.trying.isEmpty else { throw TryInCheckoutFailure.notTrying }
        let git = env.git
        var sessions = task.record.trying
        var moved = 0
        var failure: (any Error)?
        for index in sessions.indices {
            guard let repo = task.record.repo(at: sessions[index].repoRelativePath) else { continue }
            let base = task.baseURL(for: repo)
            let branch = repo.branch
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                let client = await git.client(for: base)
                do { return .success(try await client.refreshTry(branch: branch)) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let head):
                if head != sessions[index].head { moved += 1 }
                sessions[index].head = head
            case .failure(let error):
                failure = error
            }
        }
        try await writeTrying(sessions, for: task)
        refreshBases(of: task)
        if let failure { throw failure }
        return moved == 0 ? "your checkout is already at the head of \(task.branch)" : "your checkout moved to the head of \(task.branch)"
    }

    // MARK: Put back

    /// Puts every base of the task back where it was: its branch, its stash. A stash that will not apply is kept
    /// and shown in the Base panel; a base mid-operation stays as it is and the session with it, so the banner
    /// keeps offering the way back.
    @discardableResult
    func putBack(_ task: TaskState, reason: String? = nil) async throws -> String {
        guard !task.record.trying.isEmpty else { throw TryInCheckoutFailure.notTrying }
        // Marked first: a quit in the middle finishes this at the next launch rather than leaving the base detached.
        let now = Date.now
        try await writeTrying(task.record.trying.map { session in
            var session = session
            session.endingAt = session.endingAt ?? now
            return session
        }, for: task)
        var remaining: [TrySession] = []
        var kept: [(TrySession, String)] = []
        var failed: [(TrySession, any Error)] = []
        for session in task.record.trying {
            switch await putBackRepo(session, of: task) {
            case .success(.restored):
                break
            case .success(.stashKept(let sha)):
                kept.append((session, sha))
            case .failure(let error):
                var still = session
                still.endingAt = nil
                remaining.append(still)
                failed.append((session, error))
            }
        }
        try await writeTrying(remaining, for: task)
        refreshBases(of: task)
        for (session, sha) in kept {
            let repo = task.record.repo(at: session.repoRelativePath)
            problems.warn("Your checkout of \(repo?.name ?? session.repoRelativePath) is back on \(session.previousLabel), but its changes did not apply",
                          detail: "The stash is kept: `git stash list` shows it as scope-try-\(task.record.slug)-…, commit \(sha). "
                              + "The tree holds the conflicts to resolve; `git stash apply \(String(sha.prefix(10)))` tries again, "
                              + "`git stash drop` once it is in.",
                          scope: task.scopeID,
                          actions: repo.map { [.reveal(task.baseURL(for: $0).path, title: "Reveal checkout")] } ?? [])
            if let repo, let scope = scope(task.scopeID), let state = scope.repo(relativePath: Self.repoStateID(of: repo)) {
                showBase(repo: state, in: scope)
            }
        }
        for (session, error) in failed {
            let repo = task.record.repo(at: session.repoRelativePath)
            problems.error("Could not put your checkout of \(repo?.name ?? session.repoRelativePath) back",
                           detail: String(describing: error), scope: task.scopeID)
        }
        if let first = failed.first { throw first.1 }
        let backTo = task.record.trying.map(\.previousLabel).joined(separator: ", ")
        var line = "your checkout is back on \(backTo)"
        if let reason { line += " (\(reason))" }
        if !kept.isEmpty { line += "; the stash of \(kept.count == 1 ? "one repository" : "\(kept.count) repositories") did not apply and is kept" }
        return line
    }

    /// Every try, put back: at quit (nothing asks), and before a task is archived or closed.
    func putBackAll(reason: String) async {
        for task in tryingTasks {
            do { _ = try await putBack(task, reason: reason) } catch {
                Log.app.error("put back of \(task.record.slug, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// At launch: a put back that a quit or a crash cut short is finished, and a base still on a task is said so.
    func finishInterruptedPutBacks() async {
        for task in tryingTasks {
            if task.record.trying.contains(where: \.isEnding) {
                do {
                    let line = try await putBack(task, reason: "finished after the last quit")
                    problems.report(Problem(severity: .info, title: "Put your checkout back from \(task.name)", detail: line, scopeID: task.scopeID))
                } catch {
                    // Reported by `putBack`; the session stays, so the banner offers the way back.
                }
            } else {
                problems.report(Problem(severity: .warning, title: "Your checkout is still on \(task.name)",
                                        detail: "It was left on the task's branch when Scope last quit. Put back from the task or the Base panel.",
                                        scopeID: task.scopeID))
            }
        }
    }

    // MARK: Pieces

    private func putBackRepo(_ session: TrySession, of task: TaskState) async -> Result<PutBackOutcome, any Error> {
        guard let repo = task.record.repo(at: session.repoRelativePath) else { return .success(.restored) }
        let git = env.git
        let base = task.baseURL(for: repo)
        let checkout = TryCheckout(previousHead: session.previousHead, previousBranch: session.previousBranch,
                                   stashSHA: session.stashSHA, head: session.head)
        let label = GitClient.tryEditsStashLabel(task: task.record.slug)
        return await Task.detached(priority: .userInitiated) { () -> Result<PutBackOutcome, any Error> in
            let client = await git.client(for: base)
            do { return .success(try await client.endTry(checkout, editsLabel: label)) } catch { return .failure(error) }
        }.value
    }

    private func writeTrying(_ sessions: [TrySession], for task: TaskState) async throws {
        let record = try await env.tasks.setTrying(sessions, for: task.id)
        task.update(record: record)
    }

    /// The sidebar's branch label and the Base panel follow the base: both read it again.
    private func refreshBases(of task: TaskState) {
        guard let scope = scope(task.scopeID) else { return }
        scope.refreshFacts(relativePaths: Set(task.activeRepos.map(Self.repoStateID(of:))))
        base.reloadIfShowing(any: task.activeRepos.map { task.baseURL(for: $0) })
    }

    /// `RepoState.id` of a task repository: the scope folder itself is `""` there and `"."` on the task.
    private static func repoStateID(of repo: TaskRepo) -> String {
        repo.isScopeRoot ? "" : repo.repoRelativePath
    }
}
