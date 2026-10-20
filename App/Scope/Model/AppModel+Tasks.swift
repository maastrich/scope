import AppKit
import Foundation
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks

/// Task actions (spec §4.3): create, add a repo, archive, close. The worktree work runs inside the
/// `TaskManager` actor, off the main actor; the UI only sees the resulting `TaskState`.
extension AppModel {
    /// Opens the New Task sheet for a scope (⌘⇧T, sidebar footer).
    func presentNewTask(in scopeID: ScopeID? = nil) {
        guard let id = scopeID ?? currentScope?.id, scope(id)?.kind != .missing else { return }
        newTaskScopeID = id
    }

    /// Base checkouts of `repos` (relative paths, `"."` for the scope itself) in `scope`.
    private func baseURLs(of repos: [String], in scope: ScopeState) -> [URL] {
        repos.map { path in
            let normalized = TaskRepo.normalize(path)
            return normalized == "." ? scope.url : scope.url.appending(path: normalized, directoryHint: .isDirectory)
        }
    }

    /// The context file names the installed drivers read (`AGENTS.md`, `CLAUDE.md`): a task writes its
    /// projection under each, since its threads can run different drivers. `none` opts a profile out.
    var contextFileNames: [String] {
        drivers.profiles.compactMap { profile in
            guard let context = profile.context, context.mode != .none else { return nil }
            return context.file
        }
    }

    /// Task slugs and sandbox folders already used in a scope (the proposer keeps clear of them).
    private func takenTaskSlugs(in scope: ScopeState) -> Set<String> {
        var taken = Set(tasks(in: scope.id).map(\.record.slug))
        let folder = env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) { taken.formUnion(names) }
        return taken
    }

    /// What a task request turned out to be about: the repositories, and whether it continues work that
    /// already exists instead of opening a branch. Everything in it is shown and editable in the sheet.
    struct TaskRequestResolution: Sendable {
        /// Relative paths of the repositories the request names; empty when nothing was recognised.
        var repos: [String] = []
        var startPoint: TaskStartPoint = .defaultBranch
        /// The pull request the prompt named and `gh` resolved.
        var pullRequest: PullRequest?
        /// A pull request was named but could not be resolved; the reason is worth showing.
        var unresolved: String?
        /// The same without the reference's label, for a line that names it itself.
        var unresolvedReason: String?
        /// The reference that was resolved, or tried.
        var reference: PullRequestReference?
        /// A task of this scope is already bound to that pull request.
        var existingTask: TaskID?
        /// The GitHub issue the prompt asks to work on, read through `gh`: the brief opens on it, the task records it.
        var issue: Issue?
    }

    /// Reads the prompt and works out what it is about, before anything is created.
    ///
    /// `startPR`, given by the caller, is resolved among `repos` (every repository when empty). Otherwise a pull
    /// request the prompt asks to work on wins (`PullRequestReference.startPoint`; one merely cited is context): its repository comes from the `origin` remote it names (not
    /// from a folder name — `.../acme-front/pull/6613` lives in the folder `front`), its head becomes the
    /// start point and its number the task's identity. Otherwise repositories and an existing branch are
    /// matched against what the scope already knows. Local and instant except for the one `gh pr view`.
    func resolveTaskRequest(prompt: String, in scopeID: ScopeID, knownBranches: [String] = [],
                            startPR: PullRequestReference? = nil, issue: PullRequestReference? = nil,
                            repos: [String] = []) async -> TaskRequestResolution {
        guard let scope = scope(scopeID) else { return TaskRequestResolution() }
        let candidates = repoCandidates(in: scope)

        var resolution = TaskRequestResolution()
        resolution.repos = TaskTargets.repos(namedIn: prompt, among: candidates)

        let named = repos.map(TaskRepo.normalize)
        let among = named.isEmpty ? candidates : candidates.filter { named.contains(TaskRepo.normalize($0.path)) }
        if let startPR {
            return await resolve(startPR, in: scope, candidates: among, keeping: resolution)
        }
        if let issue {
            return await resolveIssue(issue, in: scope, candidates: among, keeping: resolution)
        }
        if let reference = PullRequestReference.startPoint(in: prompt) {
            // An issue URL is one for sure; a bare `#123` is tried as a pull request, and `gh` says when it is an issue.
            if reference.isIssue { return await resolveIssue(reference, in: scope, candidates: candidates, keeping: resolution) }
            let resolved = await resolve(reference, in: scope, candidates: candidates, keeping: resolution)
            if resolved.pullRequest == nil, resolved.unresolvedReason?.contains("not a pull request of a repository") != true {
                let asIssue = await resolveIssue(reference, in: scope, candidates: candidates, keeping: resolution)
                if asIssue.issue != nil { return asIssue }
            }
            return resolved
        }

        if let branch = TaskTargets.branch(namedIn: prompt, among: knownBranches) {
            resolution.startPoint = .existingBranch(branch)
        }
        return resolution
    }

    /// The scope's repositories as the New Task sheet sees them (`"."` for a repo scope).
    func repoCandidates(in scope: ScopeState) -> [RepoCandidate] {
        let isRepoScope = scope.kind == .repo || scope.repos.contains { $0.id.isEmpty }
        return isRepoScope
            ? [RepoCandidate(path: ".", name: scope.name, remote: scope.repos.first?.facts?.remote)]
            : scope.repos.map { RepoCandidate(path: $0.id, name: $0.shortName, remote: $0.facts?.remote) }
    }

    /// Turns a reference into a real pull request through `gh`, whether it was read off the prompt or
    /// answered by a microsession: the model names a pull request, `gh pr view` says what it is. The head
    /// that gets checked out never comes from the model's own words.
    func resolve(_ reference: PullRequestReference, in scope: ScopeState, candidates: [RepoCandidate],
                 keeping resolution: TaskRequestResolution) async -> TaskRequestResolution {
        var resolution = resolution
        resolution.reference = reference
        func fail(_ text: String, reason: String) -> TaskRequestResolution {
            resolution.unresolved = text
            resolution.unresolvedReason = reason
            return resolution
        }
        guard let candidate = TaskTargets.repo(for: reference, among: candidates) else {
            let reason = reference.isBare && candidates.count > 1
                ? "a bare number names no repository, and this scope holds several"
                : "not a pull request of this scope"
            return fail("\(reference.label) is not a pull request of a repository in this scope.", reason: reason)
        }
        guard let gh = GhClient.locate() else {
            return fail("\(reference.label): gh is not installed, so its branch cannot be looked up.",
                        reason: "gh is not installed to look it up")
        }
        let checkout = baseURLs(of: [candidate.path], in: scope).first ?? scope.url
        do {
            let pr = try await gh.prView(number: reference.number, in: checkout, repo: reference.fullName)
            resolution.repos = [candidate.path]
            resolution.pullRequest = pr
            resolution.startPoint = .pullRequest(pr)
            resolution.existingTask = tasks(in: scope.id).first { $0.record.primaryPullRequest?.number == pr.number }?.id
            resolution.unresolved = nil
            resolution.unresolvedReason = nil
        } catch {
            return fail("\(reference.label) could not be read: \(String(describing: error))",
                        reason: "gh could not read it (\(String(describing: error)))")
        }
        return resolution
    }

    /// Turns an issue reference into the issue itself through `gh issue view`: its title, body and labels open the
    /// brief, nothing of it becomes a checkout. The repository is found the way a pull request's is.
    func resolveIssue(_ reference: PullRequestReference, in scope: ScopeState, candidates: [RepoCandidate],
                      keeping resolution: TaskRequestResolution) async -> TaskRequestResolution {
        var resolution = resolution
        var reference = reference
        reference.isIssue = true
        resolution.reference = reference
        func fail(_ text: String, reason: String) -> TaskRequestResolution {
            resolution.unresolved = text
            resolution.unresolvedReason = reason
            return resolution
        }
        guard let candidate = TaskTargets.repo(for: reference, among: candidates) else {
            let reason = reference.isBare && candidates.count > 1
                ? "a bare number names no repository, and this scope holds several"
                : "not an issue of this scope"
            return fail("\(reference.label) is not an issue of a repository in this scope.", reason: reason)
        }
        guard let gh = GhClient.locate() else {
            return fail("\(reference.label): gh is not installed, so the issue cannot be read.", reason: "gh is not installed to read it")
        }
        let checkout = baseURLs(of: [candidate.path], in: scope).first ?? scope.url
        do {
            let issue = try await gh.issueView(number: reference.number, in: checkout, repo: reference.fullName)
            resolution.repos = [candidate.path]
            resolution.issue = issue
            resolution.unresolved = nil
            resolution.unresolvedReason = nil
        } catch {
            return fail("\(reference.label) could not be read as an issue: \(String(describing: error))",
                        reason: "gh could not read it (\(String(describing: error)))")
        }
        return resolution
    }

    /// An issue a microsession found in a request that named none literally, read through `gh` as a pasted URL
    /// would be. Nil when it resolves to nothing, so the caller keeps the proposal it has.
    func resolveProposedIssue(_ reference: PullRequestReference, in scopeID: ScopeID) async -> TaskRequestResolution? {
        guard let scope = scope(scopeID) else { return nil }
        let resolved = await resolveIssue(reference, in: scope, candidates: repoCandidates(in: scope), keeping: TaskRequestResolution())
        return resolved.issue == nil ? nil : resolved
    }

    /// `base`, or `base-2`, `base-3`… when a task or a sandbox folder of the scope already uses it.
    func uniqueTaskSlug(_ base: String, in scopeID: ScopeID) -> String {
        guard let scope = scope(scopeID) else { return base }
        return SlugAllocator.unique(base: base, taken: takenTaskSlugs(in: scope))
    }

    /// Branch-naming evidence of the repos a task would sandbox (New Task sheet, gathered once per prompt).
    func branchEvidence(for repos: [String], in scopeID: ScopeID) async -> BranchEvidence {
        guard let scope = scope(scopeID) else { return BranchEvidence() }
        return await BranchEvidence.gather(repos: baseURLs(of: repos, in: scope), registry: env.git)
    }

    /// Level 0: title / slug / branch derived from the prompt and the evidence, instantly.
    func fallbackProposal(prompt: String, evidence: BranchEvidence, in scopeID: ScopeID) -> TaskProposal {
        let taken = scope(scopeID).map(takenTaskSlugs) ?? []
        return TaskProposer.fallback(prompt: prompt, evidence: evidence, takenSlugs: taken)
    }

    /// Level 1: asks `driverID` (headless) for a branch that follows the repo's convention; falls back to
    /// `fallbackProposal` when the driver cannot answer (see `TaskProposal.source`).
    func proposeTask(prompt: String, driverID: String?, repos: [String], evidence: BranchEvidence, in scopeID: ScopeID) async -> TaskProposal {
        guard let scope = scope(scopeID) else { return TaskProposer.fallback(prompt: prompt, evidence: evidence, takenSlugs: []) }
        let profile = profile(id: driverID)
        let bases = baseURLs(of: repos, in: scope)
        let cwd = bases.first ?? scope.url
        let shell = await env.shell.environment()
        let validator = TaskProposer.gitRefValidator(client: await env.git.client(for: cwd))
        // A light run with tools may spend a while in `gh`; a plain headless one keeps the short bound.
        let timeout = profile?.headlessLight?.isEmpty == false ? TaskProposer.microsessionTimeout : TaskProposer.defaultTimeout
        let proposer = TaskProposer(
            profile: profile, runner: SubprocessHeadlessRunner(path: shell.path, shell: shell.shell), home: env.home,
            timeout: timeout, validateRef: validator
        )
        let taken = takenTaskSlugs(in: scope)
        // `propose` is nonisolated async: it runs off the main actor, and cancelling the caller's task kills the driver.
        return await proposer.propose(prompt: prompt, evidence: evidence, cwd: cwd, scopeRoot: scope.url,
                                      takenSlugs: taken, candidates: repoCandidates(in: scope))
    }

    /// A pull request a microsession found in a request that named none literally: resolved through `gh`,
    /// exactly as a pasted URL would be. Nil when it resolves to nothing usable, so the caller keeps the
    /// new-branch proposal it already has.
    func resolveProposedPullRequest(_ reference: PullRequestReference, in scopeID: ScopeID) async -> TaskRequestResolution? {
        guard let scope = scope(scopeID) else { return nil }
        let resolved = await resolve(reference, in: scope, candidates: repoCandidates(in: scope), keeping: TaskRequestResolution())
        return resolved.pullRequest == nil ? nil : resolved
    }

    /// Creates the task from a proposal, selects it unless an agent asked for it (`takesSelection`), starts its watcher, then opens its first thread with
    /// `driverID` and the prompt as the driver's opening request. Throws `TaskError` for the sheet to show inline.
    @discardableResult
    ///
    /// The sandboxes are then prepared in the background (`startSetup`): `runSetup` runs the setup commands, the
    /// `.env*` files are copied either way, and the first thread waits for it before it launches.
    func createTask(
        _ proposal: TaskProposal, prompt: String, driverID: String?, in scopeID: ScopeID, repos: [String],
        startPoint: TaskStartPoint = .defaultBranch, openThread: Bool = true, runSetup: Bool = true,
        threadOrigin: ThreadOrigin = .user, createdBy: String? = nil, topic: String? = nil, parentTask: TaskID? = nil,
        deliverable: String? = nil, model: String? = nil, issue: Issue? = nil, attempt: TaskAttempt? = nil, mission: Bool = false
    ) async throws -> TaskState {
        guard let scope = scope(scopeID) else { throw TaskError.persistence("scope not found") }
        let scopeRepos = scope.repos.map(\.id)
        let summaries = await graphSummaries(for: scope)
        // The brief opens on the issue: the thread reads it first, and the record keeps it that way.
        let prompt = issue.map { IssueBrief.prefixed(prompt, with: $0) } ?? prompt
        let record: TaskRecord
        do {
            record = try await env.tasks.create(
                name: proposal.title, branch: proposal.branch, slug: proposal.slug, initialPrompt: prompt,
                in: scope.declaration, repos: repos, startPoint: startPoint,
                pullRequest: startPoint.pullRequest.map { LinkedPullRequest($0) },
                scopeRepos: scopeRepos, repoSummaries: summaries, contextFiles: contextFileNames,
                createdBy: createdBy, topic: topic, parentTask: parentTask,
                origin: threadOrigin.author == .control ? threadOrigin : nil, deliverable: deliverable,
                issue: issue.map(LinkedIssue.init), attempt: attempt, mission: mission
            )
        } catch {
            problems.error("Could not create task “\(proposal.title)”", detail: String(describing: error), scope: scopeID)
            throw error
        }
        let state = TaskState(record: record, git: env.git)
        tasks.append(state)
        state.startWatching()
        state.refresh()
        startSetup(for: state, runCommands: runSetup)
        refreshDiskUsage(of: state)
        if takesSelection(threadOrigin, in: scopeID) { selection = .task(record.id) }
        // The base checkouts gained a worktree: refresh their facts.
        scope.refreshFacts()
        assistTaskCreated(state)
        guard openThread else { return state }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        await newThread(in: scopeID, driverID: driverID, taskID: record.id,
                        initialPrompt: trimmed.isEmpty ? nil : trimmed, origin: threadOrigin, model: model)
        return state
    }

    // MARK: Topics

    /// Files `ids` under `topic`, or out of any with `nil`, and only them (a topic renamed or ungrouped as a whole,
    /// an agent's inherited topic).
    func setTopic(_ topic: String?, for ids: [TaskID]) async {
        do {
            try await applyTopic(topic, to: ids)
        } catch {
            problems.error("Could not change the topic", detail: String(describing: error))
        }
    }

    /// Re-files tasks one at a time, the way the task menu and `scope task topic` do: the tasks each one started
    /// come along while they still share its old topic (`TaskTopic.followers`), so a piece of work moves whole.
    func fileTasks(_ ids: [TaskID], underTopic topic: String?) async {
        do {
            try await refile(ids, underTopic: topic, withChildren: true)
        } catch {
            problems.error("Could not change the topic", detail: String(describing: error))
        }
    }

    /// `fileTasks` for a caller that reports the failure itself. Returns the records that changed.
    @discardableResult
    func refile(_ ids: [TaskID], underTopic topic: String?, withChildren: Bool) async throws -> [TaskRecord] {
        var moving: [TaskID] = []
        for id in ids where !moving.contains(id) {
            moving.append(id)
            guard withChildren else { continue }
            // Every task, archived ones too: the summary groups by topic, and a finished piece should not part
            // from the rest of its work there.
            let lineage = tasks.map { (id: $0.id, parent: $0.record.parentTask, topic: $0.record.topic) }
            moving += TaskTopic.followers(of: id, in: lineage).filter { !moving.contains($0) }
        }
        return try await applyTopic(topic, to: moving)
    }

    @discardableResult
    private func applyTopic(_ topic: String?, to ids: [TaskID]) async throws -> [TaskRecord] {
        let changed = try await env.tasks.setTopic(topic, for: ids)
        for record in changed {
            task(record.id)?.update(record: record)
        }
        return changed
    }

    /// The open tasks of `scope` filed under `topic`, whatever its spelling.
    func tasks(inTopic topic: String, scope: ScopeID) -> [TaskState] {
        let key = TaskTopic.key(topic)
        return tasks(in: scope).filter { $0.record.topic.map(TaskTopic.key) == key }
    }

    /// The topics in use among the open tasks of `scope`, for the Topic submenu.
    func topics(in scope: ScopeID) -> [String] {
        TaskTopic.distinct(tasks(in: scope).map(\.record.topic))
    }

    /// Renames a topic on every open task of `scope` filed under it.
    func renameTopic(_ topic: String, to newName: String, in scope: ScopeID) async {
        guard let newName = TaskTopic.normalize(newName) else { return }
        await setTopic(newName, for: tasks(inTopic: topic, scope: scope).map(\.id))
    }

    /// "New Topic…" / "Rename Topic…": an alert with a text field. `nil` when cancelled or left empty.
    func promptTopicName(title: String, current: String?, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Tasks sharing a topic sit together in the sidebar. Agents file the tasks they create "
            + "under the topic of the task they work in."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Topic"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return TaskTopic.normalize(field.stringValue)
    }

    /// Archives every open task filed under `topic`: one piece of work, put away together. One after the other, so
    /// a failure is reported against the task it happened to and the rest still go.
    func archiveTopic(_ topic: String, in scope: ScopeID) async {
        for task in tasks(inTopic: topic, scope: scope) {
            await archiveTask(task.id)
        }
    }

    /// Adds a base repo of the scope to a running task (context menu *Add repo…*).
    func addRepo(_ relativePath: String, to taskID: TaskID) async {
        guard let task = task(taskID), let scope = scope(task.scopeID) else { return }
        do {
            let summaries = await graphSummaries(for: scope)
            let record = try await env.tasks.addRepo(taskID, repo: relativePath, scopeContext: scope.declaration.context,
                                                     scopeRepos: scope.repos.map(\.id),
                                                     repoSummaries: summaries, contextFiles: contextFileNames)
            task.update(record: record)
            task.stopWatching()
            task.startWatching()
            startSetup(for: task, runCommands: true, only: [relativePath])
        } catch {
            problems.error("Could not add \(relativePath) to \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    // MARK: Several branches

    /// `scope task branch add` and *Add Branch…*: a second worktree of one repository of the task, on `branch`
    /// (`TaskManager.addBranch`). The new sandbox gets the repository's setup — its `.env*` files and its setup
    /// command — like one added with a repository. Throws for the caller to report.
    @discardableResult
    func addBranch(_ branch: String, to taskID: TaskID, repo: String? = nil, startPoint: TaskStartPoint = .defaultBranch) async throws -> TaskRecord {
        guard let task = task(taskID), let scope = scope(task.scopeID) else { throw TaskError.persistence("no such task") }
        let summaries = await graphSummaries(for: scope)
        let record = try await env.tasks.addBranch(taskID, branch: branch, repo: repo, startPoint: startPoint,
                                                   scopeContext: scope.declaration.context, scopeRepos: scope.repos.map(\.id),
                                                   repoSummaries: summaries, contextFiles: contextFileNames)
        task.update(record: record)
        let name = startPoint.requiredBranch ?? branch
        if let added = record.activeSandboxes.last(where: { $0.isSecondary && $0.branch == name }) {
            startSetup(for: task, runCommands: true, only: [added.sandboxKey])
        }
        refreshDiskUsage(of: task)
        scope.refreshFacts()
        return record
    }

    /// `scope task branch remove` and *Remove Branch*: the worktree on `branch` leaves the task, its threads hung up
    /// first and its uncommitted changes saved (`TaskManager.removeBranch`). The notice says where they went.
    @discardableResult
    func removeBranch(_ branch: String, from taskID: TaskID, repo: String? = nil) async throws -> [DismantleNotice] {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let leaving = task.record.sandboxes(onBranch: branch).filter(\.isSecondary).map(\.sandboxURL.standardizedFileURL.path)
        for session in threads(in: taskID) {
            let cwd = URL(fileURLWithPath: session.record.cwd).standardizedFileURL.path
            guard leaving.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }
            await close(session.id, force: true)
        }
        let (record, notices) = try await env.tasks.removeBranch(taskID, branch: branch, repo: repo)
        task.update(record: record)
        if currentTask?.id == taskID { await delta.load(task: task) }
        refreshDiskUsage(of: task)
        scope(task.scopeID)?.refreshFacts()
        var saved: [String] = []
        for notice in notices {
            if case .changesSaved(let repo, let ref, let skipped) = notice {
                saved.append("\(repo): uncommitted changes → \(ref)" + (skipped.isEmpty ? "" : " (too big to keep, deleted: \(skipped.joined(separator: ", ")))"))
            }
        }
        if !saved.isEmpty {
            problems.report(Problem(severity: .info, title: "\(task.name): unfinished work on \(branch) saved",
                                    detail: saved.joined(separator: "\n"), scopeID: task.scopeID))
        }
        return notices
    }

    /// *Add Branch…* (context menu, palette): an alert asking for the branch, then `addBranch` on the task's only
    /// repository — or the one picked in the alert when the task holds several. The failure goes to the problem list.
    func addBranchFromUI(_ task: TaskState) {
        Usage.click("task.add-branch", label: "Add a branch to the task")
        let repos = task.activeRepos
        let alert = NSAlert()
        alert.messageText = "Add a branch to “\(task.name)”"
        alert.informativeText = "A second worktree of the repository, on that branch, beside the task's sandbox — for a second "
            + "pull request on the same repository. The branch starts from the repository's base; `scope task branch add --from` "
            + "starts it from an existing one."
        alert.addButton(withTitle: "Add Branch")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "fix/login-redirect"
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for repo in repos { picker.addItem(withTitle: repo.isScopeRoot ? task.record.scopeName : repo.repoRelativePath) }
        let stack = NSStackView(views: repos.count > 1 ? [picker, field] : [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: repos.count > 1 ? 56 : 24)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        picker.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        let repo = repos.count > 1 ? repos[max(0, picker.indexOfSelectedItem)].repoRelativePath : nil
        Task {
            do { try await addBranch(branch, to: task.id, repo: repo) } catch {
                problems.error("Could not add \(branch) to \(task.name)", detail: String(describing: error), scope: task.scopeID)
            }
        }
    }

    /// *Remove Branch* for a secondary sandbox: no question — the uncommitted work is saved and the notice says so.
    func removeBranchFromUI(_ sandbox: TaskRepo, of task: TaskState) {
        Usage.click("task.remove-branch", label: "Remove a branch from the task")
        Task {
            do { try await removeBranch(sandbox.branch, from: task.id, repo: sandbox.repoRelativePath) } catch {
                problems.error("Could not remove \(sandbox.branch) from \(task.name)", detail: String(describing: error), scope: task.scopeID)
            }
        }
    }

    // MARK: Setup and teardown

    /// The setup / teardown commands and the copied files of each repository of a task: its graph card, with the
    /// scope's config (`repoCommands` in `config.json`) over it.
    func sandboxCommands(for record: TaskRecord) async -> [String: SandboxCommands] {
        guard let scope = scope(record.scopeID) else { return [:] }
        let cards = Dictionary(await graphSummaries(for: scope).map { (TaskRepo.normalize($0.path), $0) },
                               uniquingKeysWith: { first, _ in first })
        var commands: [String: SandboxCommands] = [:]
        for repo in record.repos {
            let override = scope.declaration.commandOverride(for: repo.repoRelativePath)
            commands[repo.repoRelativePath] = SandboxCommands.resolve(
                card: cards[repo.repoRelativePath], setupOverride: override?.setup,
                teardownOverride: override?.teardown, copyFilesOverride: override?.copyFiles
            )
        }
        return commands
    }

    /// Commands run in the login-shell environment the threads get, resolved once per app run.
    private func commandRunner() async -> ShellCommandRunner {
        let shell = await env.shell.environment()
        return ShellCommandRunner(shell: shell.shell, baseEnvironment: shell.variables)
    }

    /// Prepares a task's sandboxes in the background (`TaskManager.runSetup`). Its threads wait for this before
    /// they launch; a setup asked for while another runs goes after it.
    func startSetup(for task: TaskState, runCommands: Bool, only: [String]? = nil) {
        let id = task.id
        let token = UUID()
        let previous = setupRuns[id]?.run
        let run = Task { [weak self] in
            await previous?.value
            await self?.performSetup(task, runCommands: runCommands, only: only)
            if self?.setupRuns[id]?.token == token { self?.setupRuns[id] = nil }
        }
        setupRuns[id] = (token, run)
    }

    private func performSetup(_ task: TaskState, runCommands: Bool, only: [String]?) async {
        let commands = await sandboxCommands(for: task.record)
        let runner = await commandRunner()
        do {
            let record = try await env.tasks.runSetup(task.id, commands: commands, runCommands: runCommands,
                                                      runner: runner, only: only) { record in
                await MainActor.run { task.update(record: record) }
            }
            // A setup is what fills a sandbox (`node_modules`): the size shown is stale until measured again.
            refreshDiskUsage(of: task)
            guard record.setupState == .failed else { return }
            problems.error("The setup of \(task.name) failed", detail: SetupLog.tail(record.setup?.log ?? "", lines: 60),
                           scope: task.scopeID,
                           actions: [ProblemAction(title: "Run Setup Again", kind: .rerunTaskSetup(task.id.rawValue)),
                                     .reveal(record.threadCwd.path, title: "Reveal Sandbox")])
        } catch {
            // Closed or archived mid-setup: nothing left to report on.
            guard !Task.isCancelled, self.task(task.id) != nil else { return }
            problems.error("Could not run the setup of \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// A setup still running when its task goes: its commands are killed rather than left writing into a folder
    /// about to be removed.
    private func cancelSetup(_ taskID: TaskID) {
        setupRuns[taskID]?.run.cancel()
        setupRuns[taskID] = nil
    }

    private func teardown(for task: TaskState) async -> TaskManager.Teardown {
        TaskManager.Teardown(commands: await sandboxCommands(for: task.record), runner: await commandRunner())
    }

    /// What `TaskStatus.resolve` decides from: the task's threads, its delta, its setup and its pull requests.
    func taskFacts(for task: TaskState) -> TaskFacts {
        TaskFacts(threads: threads(in: task.id).map(\.displayState), additions: task.totalAdditions,
                  deletions: task.totalDeletions, isDirty: task.dirtyRepoCount > 0, setup: task.record.setupState,
                  pullRequests: pullRequestFacts(for: task))
    }

    /// Repos of the task's scope that are not part of the task yet.
    func candidateRepos(for task: TaskState) -> [RepoState] {
        guard let scope = scope(task.scopeID) else { return [] }
        if task.record.isMonoRepo { return [] }
        let taken = Set(task.record.repos.map(\.repoRelativePath))
        return scope.repos.filter { !taken.contains($0.id) && !$0.id.isEmpty }
    }

    /// Removes the worktrees, keeps the branches and the record. One click, no question: uncommitted changes are
    /// saved first and the notice offers them back (`reopenTask`).
    func archiveTask(_ taskID: TaskID) async {
        guard let task = task(taskID), !task.isDismantling else { return }
        do { try await dismantle(task, .archive) } catch { dismantleFailed(task, verb: "archive", error: error) }
    }

    /// Closes the task for good: threads hung up, worktrees removed, record deleted, the branch too when asked.
    /// Nothing asks: what could be lost is saved under `refs/scope/salvage/` and the notice says where.
    func closeTask(_ taskID: TaskID, deleteBranch: Bool) async {
        guard let task = task(taskID), !task.isDismantling else { return }
        do { try await dismantle(task, .close(deleteBranch: deleteBranch)) } catch {
            dismantleFailed(task, verb: "close", error: error)
        }
    }

    /// Archive or close for the control socket: the failure goes back to the caller instead of the problem list.
    /// `notice` is the title of a notice posted whatever was saved (`archiveIfMerged`), with Restore on an archive.
    @discardableResult
    func dismantleTask(_ taskID: TaskID, _ mode: DismantleMode, notice: String? = nil) async throws -> DismantleOutcome {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        return try await dismantle(task, mode, notice: notice)
    }

    /// The Retry of a failed archive or close: the same run again, from where the last one stopped.
    func retryCleanup(_ taskID: TaskID) async {
        guard let task = task(taskID) else { return }
        switch task.record.cleanup?.mode ?? .archive {
        case .archive: await archiveTask(taskID)
        case .close(let deleteBranch): await closeTask(taskID, deleteBranch: deleteBranch)
        }
    }

    /// The Restore of an archive notice: the task comes back with its sandboxes and the changes it had.
    func reopenTask(_ taskID: TaskID) async {
        guard let task = task(taskID), task.record.isArchived else { return }
        do {
            try await restoreTask(taskID)
            selection = .task(taskID)
        } catch {
            problems.error("Could not restore \(task.name)", detail: String(describing: error), scope: task.scopeID)
        }
    }

    /// `reopenTask` for a caller that reports the failure itself and leaves the selection alone (`task.restore`).
    @discardableResult
    func restoreTask(_ taskID: TaskID) async throws -> TaskRecord {
        guard let task = task(taskID) else { throw TaskError.persistence("no such task") }
        let record = try await env.tasks.reopen(taskID)
        task.update(record: record)
        task.startWatching()
        refreshDiskUsage(of: task)
        if let scope = scope(task.scopeID) { await refreshContextFiles(of: scope) }
        scope(task.scopeID)?.refreshFacts()
        return record
    }

    /// Archive and close: the row leaves the live list at once, the task manager does the rest (threads hung up
    /// inside its lock, through `prepare`), and the outcome is reported.
    @discardableResult
    private func dismantle(_ task: TaskState, _ mode: DismantleMode, notice: String? = nil) async throws -> DismantleOutcome {
        task.isDismantling = true
        if selection == .task(task.id) || currentTask?.id == task.id { selection = .scope(task.scopeID) }
        // A base still on the task's branch goes back first: the branch may be about to be deleted.
        if !task.record.trying.isEmpty {
            do { _ = try await putBack(task, reason: mode.isClose ? "task closed" : "task archived") } catch {
                task.isDismantling = false
                throw error
            }
        }
        await settlePullRequest(of: task)
        let outcome: DismantleOutcome
        do {
            // Read before `prepare` hangs the threads up: a closed session's last answer goes with it.
            outcome = try await env.tasks.dismantle(task.id, mode, teardown: await teardown(for: task),
                                                    replies: keptReplies(of: task.id), prepare: hangUp(task.id))
        } catch {
            // The record says how far the run got; `cleanup` keeps the row out of the live list until a retry.
            task.isDismantling = false
            if let record = await env.tasks.task(task.id) { task.update(record: record) }
            throw error
        }
        task.isDismantling = false
        if let record = outcome.record {
            task.stopWatching()
            task.update(record: record)
            scope(task.scopeID)?.refreshFacts()
        } else {
            forgetClosedTask(task)
        }
        reportOutcome(outcome, task: task, mode: mode, notice: notice)
        Task { await collectGarbage() }
        return outcome
    }

    /// What GitHub says of the task's pull request now, written on the record before the task is taken apart: the
    /// inspector only refreshes the task on screen, and an agent archives right after a merge it saw on GitHub.
    /// Without this the record would keep `open`, and a summary would call shipped work merely delivered. Binds the
    /// pull request a thread opened, too. Never holds the archive up past `pullRequestSettleTimeout`; a refresh that
    /// finishes later still lands on an archived record.
    private func settlePullRequest(of task: TaskState) async {
        guard pullRequests.gh != nil, !PullRequestSet.isSettled(task.record.pullRequests.map(\.state)) else { return }
        let race = SettleRace()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await refreshTaskPullRequest(task)
                race.finish(continuation)
            }
            Task {
                try? await Task.sleep(for: AppModel.pullRequestSettleTimeout)
                race.finish(continuation)
            }
        }
    }

    static let pullRequestSettleTimeout: Duration = .seconds(5)

    // MARK: Garbage collection

    static let garbageCollectionInterval: Duration = .seconds(30 * 60)

    /// A pass now (finishing the archives and closes a quit or a crash interrupted), then one every 30 minutes.
    func startGarbageCollection() {
        garbageCollector?.cancel()
        garbageCollector = Task { [weak self] in
            await self?.collectGarbage(resumingPending: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.garbageCollectionInterval)
                guard !Task.isCancelled else { return }
                await self?.collectGarbage()
            }
        }
    }

    /// One pass of `TaskManager.collectGarbage` over every scope, when Settings ▸ Tasks allows it. Quiet: one info
    /// line when it removed something, an error only for a process that would not die.
    /// `resumingPending` also reruns the archives and closes left half-done — at launch only, so a run that keeps
    /// failing is reported once per launch rather than every half hour.
    @discardableResult
    /// `force` runs it even with the preference off: someone asked for it (`scope gc`).
    func collectGarbage(dryRun: Bool = false, resumingPending: Bool = false, force: Bool = false) async -> GarbageReport? {
        guard dryRun || force || config.preferences.cleanUpAutomatically else { return nil }
        let bases = scopes.flatMap { scope in
            scope.repos.map { repo in
                repo.id.isEmpty || repo.id == "." ? URL(fileURLWithPath: scope.declaration.path, isDirectory: true)
                    : URL(fileURLWithPath: scope.declaration.path, isDirectory: true).appending(path: repo.id, directoryHint: .isDirectory)
            }
        }
        let report = await env.tasks.collectGarbage(extraBases: bases, dryRun: dryRun)
        guard !dryRun else { return report }
        if resumingPending {
            for id in report.pendingTasks { await retryCleanup(id) }
        }
        if !report.keptFolders.isEmpty {
            problems.warn("\(report.keptFolders.count) leftover sandbox \(report.keptFolders.count == 1 ? "folder was" : "folders were") kept",
                          detail: report.keptFolders.joined(separator: "\n"))
        }
        if !report.survivors.isEmpty {
            problems.error("\(report.survivors.count) leftover \(report.survivors.count == 1 ? "process" : "processes") would not stop",
                           detail: report.survivors.joined(separator: "\n"))
        }
        var done: [String] = []
        if !report.removedFolders.isEmpty { done.append("\(report.removedFolders.count) leftover sandbox \(report.removedFolders.count == 1 ? "folder" : "folders")") }
        if !report.stoppedProcesses.isEmpty { done.append("\(report.stoppedProcesses.count) leftover \(report.stoppedProcesses.count == 1 ? "process" : "processes")") }
        if !report.prunedWorktrees.isEmpty { done.append("stale worktrees in \(report.prunedWorktrees.count) \(report.prunedWorktrees.count == 1 ? "repository" : "repositories")") }
        if !report.savedChanges.isEmpty { done.append("saved the uncommitted work of \(report.savedChanges.count) of them") }
        if !report.deletedRefs.isEmpty { done.append("\(report.deletedRefs.count) expired saved \(report.deletedRefs.count == 1 ? "change" : "changes")") }
        if !done.isEmpty {
            let detail = (report.removedFolders + report.savedChanges + report.stoppedProcesses + report.prunedWorktrees
                + report.deletedRefs).joined(separator: "\n")
            problems.report(Problem(severity: .info, title: "Cleaned up " + done.joined(separator: ", "), detail: detail))
        }
        return report
    }

    /// What each of the task's threads last answered, for `TaskDeliverable`: the activity's copy (kept across
    /// restarts) or the session's own, whichever is there.
    func keptReplies(of taskID: TaskID) -> [TaskDeliverable.Reply] {
        threads(in: taskID).compactMap { session in
            guard let reply = session.activity.lastReply ?? session.lastReply else { return nil }
            return TaskDeliverable.Reply(threadID: session.id.rawValue, title: session.title, driver: session.record.driverID,
                                         text: reply.text, at: reply.at)
        }
    }

    /// `prepare` for `TaskManager.dismantle`: runs inside the task's lock, before the teardown and the sweep.
    private func hangUp(_ taskID: TaskID) -> @Sendable () async -> Void {
        { [weak self] in await self?.hangUpThreads(of: taskID) }
    }

    private func hangUpThreads(of taskID: TaskID) async {
        cancelSetup(taskID)
        for session in threads(in: taskID) {
            await close(session.id, force: true)
        }
    }

    func dismantleFailed(_ task: TaskState, verb: String, error: any Error) {
        problems.error("Could not \(verb) \(task.name)", detail: String(describing: error), scope: task.scopeID,
                       actions: [ProblemAction(title: "Retry", kind: .retryTaskCleanup(task.id.rawValue)),
                                 .reveal(task.record.root, title: "Reveal Task Folder")])
    }

    private func reportOutcome(_ outcome: DismantleOutcome, task: TaskState, mode: DismantleMode, notice: String? = nil) {
        var saved: [String] = []
        for notice in outcome.notices {
            switch notice {
            case .teardownFailed(let repo, let summary, let log):
                problems.warn("The teardown of \(task.name) failed; its sandboxes were removed anyway",
                              detail: "\(repo): \(summary)\n\n\(SetupLog.tail(log, lines: 60))", scope: task.scopeID)
            case .processesSurvived(let names):
                problems.error("\(names.count) \(names.count == 1 ? "process" : "processes") of \(task.name) would not stop",
                               detail: names.joined(separator: "\n"), scope: task.scopeID)
            case .changesSaved(let repo, let ref, let skipped):
                saved.append("\(repo): uncommitted changes → \(ref)"
                             + (skipped.isEmpty ? "" : " (too big to keep, deleted: \(skipped.joined(separator: ", ")))"))
            case .branchSaved(let repo, let branch, let ref):
                saved.append("\(repo): unmerged branch \(branch) → \(ref)")
            }
        }
        guard !saved.isEmpty || notice != nil else { return }
        // Quiet: the work is safe, nothing to do unless the user wants it back. One notice, whoever asked for it.
        let actions = mode == .archive ? [ProblemAction(title: "Restore", kind: .reopenTask(task.id.rawValue))] : []
        problems.report(Problem(severity: .info, title: notice ?? "\(task.name): unfinished work saved",
                                detail: saved.isEmpty ? nil : saved.joined(separator: "\n"), scopeID: task.scopeID,
                                actions: actions))
    }

    /// What is left to do once the task manager has removed a task.
    private func forgetClosedTask(_ task: TaskState) {
        let taskID = task.id
        task.stopWatching()
        let reviews = review.store
        let viewed = delta.viewedStore
        Task {
            await reviews.delete(taskID)
            await viewed.delete(taskID)
        }
        tasks.removeAll { $0.id == taskID }
        if selection == .task(taskID) || currentTask?.id == taskID {
            selection = .scope(task.scopeID)
        }
        scope(task.scopeID)?.refreshFacts()
    }

    func confirmForce(title: String, detail: String, button: String, destructive: Bool = true) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}

/// Whichever of the refresh and the deadline comes first resumes the archive; the other finds it done.
@MainActor
private final class SettleRace {
    private var done = false

    func finish(_ continuation: CheckedContinuation<Void, Never>) {
        guard !done else { return }
        done = true
        continuation.resume()
    }
}
