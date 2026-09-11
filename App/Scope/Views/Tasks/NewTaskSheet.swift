import SwiftUI
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks

/// ⌘⇧T, two steps. **Prompt**: what the agent should do, and the driver — nothing else to fill in.
///
/// **Continue** reads the prompt (`TaskTargets`, `PullRequestReference`) and works out what it is about:
/// the repositories it names, and whether it continues work that already exists — a pull request whose head
/// must be checked out, or a branch of the repo. Without one, the title / branch / folder are derived from
/// the prompt at once (level 0) and a microsession of the driver's light model is asked for a branch that
/// follows the repo's own convention, the repositories the work touches, and any pull request the request
/// only alludes to — which it looks up with `gh` (level 1, replaces the fields when it answers, cancellable).
///
/// Everything it worked out is shown and editable before **Create**: a wrong branch name is a typo, a wrong
/// repository is a worktree in the wrong place. Errors show inline and in the Problem Center.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: ScopeState

    private enum Step { case prompt, proposal }

    @State private var step: Step = .prompt
    @State private var prompt = ""
    @State private var driverID: String
    @State private var selectedRepos: Set<String> = []
    @State private var evidence: BranchEvidence?
    @State private var startPoint: TaskStartPoint = .defaultBranch
    @State private var resolution: AppModel.TaskRequestResolution?
    @State private var resolving = false
    /// The branch proposed for a *new* branch, kept aside so switching "Start from" back to one restores it
    /// instead of leaving the pull request's branch name behind.
    @State private var derivedBranch = ""
    @State private var title = ""
    @State private var branch = ""
    @State private var folder = ""
    @State private var source: TaskProposal.Source?
    @State private var fieldsEdited = false
    /// The repository selection was ticked by hand; a microsession answer no longer touches it.
    @State private var reposEdited = false
    /// Last values written by `apply`; an `onChange` back to one of them is our own write, not an edit.
    @State private var appliedFields: [String] = ["", "", ""]
    @State private var proposing: Task<Void, Never>?
    @State private var isCreating = false
    @State private var runSetup = true
    /// The branch Create asked for is checked out in another working tree: which one, said in words.
    @State private var checkedOut: (branch: String, holder: String)?
    @State private var error: String?
    @FocusState private var promptFocused: Bool
    @FocusState private var titleFocused: Bool

    init(scope: ScopeState, defaultDriverID: String) {
        self.scope = scope
        _driverID = State(initialValue: defaultDriverID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch step {
                case .prompt: promptSections
                case .proposal: proposalSections
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            // Outside the Form on purpose. As its last section the message was the bottom of a scrolling list
            // nothing scrolled to, so a failed Create looked like nothing happening at all — the only legible
            // copy was in the toolbar's problem popover.
            if let error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 10, leading: 20, bottom: 2, trailing: 20))
            }

            buttonRow
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 520)
        .frame(minHeight: 300, maxHeight: 600)
        .onAppear {
            promptFocused = true
            if !isRepoScope, scope.repos.count == 1, let only = scope.repos.first {
                selectedRepos = [only.id]
            }
        }
        .onDisappear { proposing?.cancel() }
    }

    // MARK: Step 1 — prompt

    @ViewBuilder private var promptSections: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should the agent do? e.g. Add a refresh-token flow to the auth service…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84, maxHeight: 168)
                    .focused($promptFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), canContinue else { return .ignored }
                        continueToProposal()
                        return .handled
                    }
            }
            .padding(.vertical, 2)
        } header: {
            Text("New Task in \(scope.name)")
        } footer: {
            Text("The prompt opens the first thread of the task and is kept in AGENTS.md as its goal. ⌘↩ continues.")
        }

        Section {
            Picker("Driver", selection: $driverID) {
                ForEach(model.drivers.profiles) { profile in
                    Label(profile.name, systemImage: profile.icon ?? "terminal").tag(profile.id)
                }
            }
            Text(driverCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Label(repoHint, systemImage: repoHintSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 2 — proposal

    @ViewBuilder private var proposalSections: some View {
        Section {
            TextField("Title", text: $title)
                .focused($titleFocused)
                .onChange(of: title) { if title != appliedFields[0] { fieldsEdited = true } }
            TextField("Branch", text: $branch)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .disabled(startPoint.continuesExistingWork)
                .onChange(of: branch) { if branch != appliedFields[1] { fieldsEdited = true } }
            TextField("Folder", text: $folder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .onChange(of: folder) { if folder != appliedFields[2] { fieldsEdited = true } }
            Picker("Start from", selection: $startPoint) {
                ForEach(startPointOptions, id: \.self) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .onChange(of: startPoint) { _, option in startPointChanged(option) }
            LabeledContent("Sandbox") {
                Text(sandboxPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(sandboxPath)
            }
        } header: {
            Text("New Task in \(scope.name)")
        } footer: {
            HStack(spacing: 6) {
                if proposing != nil {
                    ProgressView().controlSize(.mini)
                    Text(resolving ? "Reading the request…" : "\(selectedProfile?.name ?? "The driver") is reading the repositories…")
                    Button("Stop") { cancelProposing() }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                } else {
                    Text(sourceCaption)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }

        if let busy = checkedOut {
            Section {
                Label("\(busy.branch) is checked out in \(busy.holder), and a branch lives in one working tree at a time.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create on a New Branch Instead") { useNewBranch(instead: busy.branch) }
                    .controlSize(.small)
            }
        }

        if let existing = resolution?.existingTask, let task = model.task(existing) {
            Section {
                Label("\(task.name) already works on this pull request.", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                Button("Open it instead") {
                    model.selection = .task(existing)
                    dismiss()
                }
                .controlSize(.small)
            }
        }

        if !isRepoScope {
            Section {
                ForEach(scope.repos) { repo in
                    Toggle(isOn: binding(for: repo.id)) {
                        HStack(spacing: 6) {
                            Text(repo.id).font(.system(size: 12))
                            if let branch = repo.branchLabel {
                                Text(branch)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(startPoint.pullRequest != nil && !selectedRepos.contains(repo.id))
                }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    if scope.repos.count > 1, startPoint.pullRequest == nil {
                        Button("All") { reposEdited = true; selectedRepos = Set(scope.repos.map(\.id)) }
                        Button("None") { reposEdited = true; selectedRepos = [] }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            } footer: {
                if !repoFooter.isEmpty { Text(repoFooter) }
            }
        }

        Section {
            Toggle("Run setup", isOn: $runSetup)
                .toggleStyle(.checkbox)
        } footer: {
            Text("Runs each repository's setup command — from its Graph card, or the scope's config — in the new sandbox before the first thread starts. The .env files of the base checkout are copied either way.")
        }

        Section {
            Text(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            LabeledContent("Opens") {
                Text("\(selectedProfile?.name ?? "Shell") in \(repoCaption)")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        } header: {
            Text("Prompt")
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating \(repoCount) \(repoCount == 1 ? "sandbox" : "sandboxes") — fetching origin…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if step == .proposal {
                Button("Back") { backToPrompt() }
                    .disabled(isCreating)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            switch step {
            case .prompt:
                Button("Continue") { continueToProposal() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            case .proposal:
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
    }

    // MARK: Derived

    private var isRepoScope: Bool {
        scope.kind == .repo || scope.repos.contains { $0.id.isEmpty }
    }

    private var selectedProfile: DriverProfile? { model.drivers.profile(id: driverID) }

    private var driverCaption: String {
        guard let profile = selectedProfile else { return "The branch name is derived from the prompt." }
        if profile.headlessLight?.isEmpty == false {
            return "\(profile.name) reads the request with its light model — the branch name from the repo's own conventions, the repositories it touches, and any pull request it refers to — then opens the first thread."
        }
        if profile.headless?.isEmpty == false {
            return "\(profile.name) proposes the branch name from the repo's existing conventions, then opens the first thread."
        }
        return "\(profile.name) has no headless mode: the branch name is derived from the prompt."
    }

    /// What step 1 promises: Scope reads the prompt, the sheet does not ask for a repository.
    private var repoHint: String {
        if isRepoScope { return "Sandbox: a worktree of \(scope.name) on the task branch." }
        return "Name a repository, a branch or a pull request in the prompt and Scope picks them up — you confirm everything on the next step."
    }

    private var repoHintSymbol: String { isRepoScope ? "info.circle" : "wand.and.stars" }

    private var repoFooter: String {
        if startPoint.pullRequest != nil {
            return "A pull request lives in one repository, so this task sandboxes that one."
        }
        if selectedRepos.isEmpty { return "Pick at least one repository." }
        if resolution?.repos.isEmpty == false, Set(resolution?.repos ?? []) == selectedRepos {
            return "Named in the prompt."
        }
        return ""
    }

    /// The start points offered: a new branch, the pull request the prompt named, the branch it named, and
    /// the repository's other branches (the evidence already gathered for the proposal).
    private var startPointOptions: [TaskStartPoint] {
        var options: [TaskStartPoint] = []
        if let pr = resolution?.pullRequest { options.append(.pullRequest(pr)) }
        options.append(.defaultBranch)
        var seen = Set<String>()
        for name in (evidence?.branches ?? []) where seen.insert(name).inserted {
            options.append(.existingBranch(name))
            if options.count > 16 { break }
        }
        if case .existingBranch(let name) = startPoint, !seen.contains(name) {
            options.insert(.existingBranch(name), at: min(1, options.count))
        }
        return options
    }

    private func label(for option: TaskStartPoint) -> String {
        switch option {
        case .defaultBranch: "A new branch"
        case .existingBranch(let name): name
        case .pullRequest(let pr): "#\(pr.number) \(pr.title)"
        }
    }

    private var sourceCaption: String {
        if let unresolved = resolution?.unresolved { return unresolved }
        switch startPoint {
        case .pullRequest(let pr):
            return "Checks \(pr.isCrossRepository ? "the fork's head" : pr.headRefName) out — no branch is created."
        case .existingBranch(let name):
            return "Continues \(name) — no branch is created."
        case .defaultBranch:
            switch source {
            case .driver(let name): return "Suggested by \(name)."
            case .derived(let reason?): return "Derived from the prompt — \(reason)"
            case .derived(nil), nil: return "Derived from the prompt."
            }
        }
    }

    private var repos: [String] {
        isRepoScope ? ["."] : scope.repos.map(\.id).filter { selectedRepos.contains($0) }
    }

    private var repoCaption: String {
        isRepoScope ? scope.name : repos.joined(separator: " · ")
    }

    private var sandboxPath: String {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(model.env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug).path)/\(name.isEmpty ? "…" : name)"
    }

    private var repoCount: Int { isRepoScope ? 1 : selectedRepos.count }

    private var canContinue: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canCreate: Bool {
        !isCreating && proposing == nil && repoCount > 0
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { selectedRepos.contains(repo) },
            set: { on in
                reposEdited = true
                if on { selectedRepos.insert(repo) } else { selectedRepos.remove(repo) }
            }
        )
    }

    // MARK: Actions

    private func continueToProposal() {
        guard canContinue else { return }
        error = nil
        fieldsEdited = false
        reposEdited = false
        appliedFields = ["", "", ""]
        step = .proposal
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeID = scope.id
        let driver = driverID
        resolution = nil
        startPoint = .defaultBranch
        resolving = true
        proposing?.cancel()
        proposing = Task {
            // 1. What is the prompt about? Local, except for one `gh pr view` when it names a pull request.
            let resolved = await model.resolveTaskRequest(prompt: request, in: scopeID)
            guard !Task.isCancelled else { return }
            resolution = resolved
            resolving = false
            if isRepoScope {
                selectedRepos = ["."]
            } else if !resolved.repos.isEmpty {
                selectedRepos = Set(resolved.repos)
            } else if selectedRepos.isEmpty, scope.repos.count == 1, let only = scope.repos.first {
                selectedRepos = [only.id]
            }

            // 2. The branches of the repos in play — the proposal's evidence, and the "Start from" list.
            let evidenceRepos = repos.isEmpty ? (isRepoScope ? ["."] : scope.repos.map(\.id)) : repos
            let evidence = await model.branchEvidence(for: evidenceRepos, in: scopeID)
            guard !Task.isCancelled else { return }
            self.evidence = evidence

            // 3. A pull request settles the name, the branch and the folder: nothing to propose.
            if let pr = resolved.pullRequest {
                derivedBranch = model.fallbackProposal(prompt: request, evidence: evidence, in: scopeID).branch
                applyPullRequest(pr, in: scopeID, force: true)
                titleFocused = true
                proposing = nil
                return
            }

            // 4. Otherwise: level 0 now, the microsession's answer when it comes.
            if let branch = TaskTargets.branch(namedIn: request, among: evidence.branches) {
                startPoint = .existingBranch(branch)
            }
            apply(model.fallbackProposal(prompt: request, evidence: evidence, in: scopeID), force: true)
            titleFocused = true
            if startPoint == .defaultBranch, model.drivers.profile(id: driver)?.microsession?.isEmpty == false {
                let proposal = await model.proposeTask(prompt: request, driverID: driver, repos: evidenceRepos, evidence: evidence, in: scopeID)
                guard !Task.isCancelled else { return }
                applyRepos(proposal.repos)
                // The microsession recognised a pull request the prompt only alluded to: `gh` says what it
                // is, and it settles the fields the same way a pasted URL would.
                if let reference = proposal.pullRequest,
                   let resolved = await model.resolveProposedPullRequest(reference, in: scopeID),
                   let pr = resolved.pullRequest {
                    guard !Task.isCancelled else { return }
                    resolution = resolved
                    applyRepos(resolved.repos)
                    applyPullRequest(pr, in: scopeID, force: false)
                } else {
                    apply(proposal, force: false)
                }
            }
            proposing = nil
        }
    }

    /// The repositories the microsession named, unless the selection was ticked by hand meanwhile.
    ///
    /// The branch evidence was gathered before the answer, from the selection as it stood, so a branch name
    /// is unique among *those* repositories' branches — not necessarily among a repository the answer adds.
    /// Git refuses a duplicate branch at creation time and the field is editable, which is cheaper than
    /// gathering the evidence twice for every prompt.
    private func applyRepos(_ repos: [String]) {
        guard !isRepoScope, !reposEdited, !repos.isEmpty else { return }
        selectedRepos = Set(repos)
    }

    /// A resolved pull request owns the task's identity: its title, its folder and its head as the branch,
    /// with the proposed new-branch name kept in `derivedBranch` so the "Start from" picker can go back.
    private func applyPullRequest(_ pr: PullRequest, in scopeID: ScopeID, force: Bool) {
        // Setting the start point rewrites the branch field on its own (`startPointChanged`), so an answer
        // that arrives after the user typed has to keep out entirely, not just skip `apply`.
        guard force || !fieldsEdited else { return }
        startPoint = .pullRequest(pr)
        apply(TaskProposal(
            title: TaskManager.taskName(forPullRequest: pr),
            slug: model.uniqueTaskSlug(TaskManager.taskSlug(forPullRequest: pr), in: scopeID),
            branch: TaskStartPoint.pullRequest(pr).requiredBranch ?? pr.headRefName,
            source: .derived(reason: nil)
        ), force: force)
    }

    /// The start point owns the branch: keep the field in step with the picker, and put the proposed name
    /// back when the answer is "a new branch" again.
    private func startPointChanged(_ option: TaskStartPoint) {
        let name = option.requiredBranch ?? derivedBranch
        guard !name.isEmpty else { return }
        branch = name
        appliedFields[1] = name
    }

    /// Fills the fields; a level-1 answer does not clobber what the user already typed.
    private func apply(_ proposal: TaskProposal, force: Bool) {
        if !force, fieldsEdited {
            source = proposal.source
            return
        }
        title = proposal.title
        branch = startPoint.requiredBranch ?? proposal.branch
        folder = proposal.slug
        if startPoint.requiredBranch == nil { derivedBranch = proposal.branch }
        appliedFields = [title, branch, folder]
        source = proposal.source
        fieldsEdited = false
    }

    private func cancelProposing() {
        proposing?.cancel()
        proposing = nil
        if case .driver = source {} else if let name = selectedProfile?.name {
            source = .derived(reason: "\(name) was stopped")
        }
    }

    private func backToPrompt() {
        cancelProposing()
        error = nil
        step = .prompt
        promptFocused = true
    }

    /// Leaves the busy branch to whoever holds it: the proposed name, or the next free `-2`, `-3`, off the base.
    private func useNewBranch(instead busy: String) {
        let base = derivedBranch.isEmpty ? busy : derivedBranch
        let name = TaskBranch.alternative(to: base, taken: Set(evidence?.branches ?? []).union([busy]))
        // Set before the start point: its change handler writes `derivedBranch` into the field.
        derivedBranch = name
        startPoint = .defaultBranch
        branch = name
        appliedFields[1] = name
        checkedOut = nil
        error = nil
    }

    /// `path` in words: a task's sandbox by the task's name, the scope's own checkout as such, else the path.
    private func holder(of path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        func same(_ other: String) -> Bool { URL(fileURLWithPath: other).resolvingSymlinksInPath().path == resolved }
        if let task = model.tasks.first(where: { $0.record.repos.contains { same($0.sandboxPath) } }) {
            return "the sandbox of the task “\(task.name)”"
        }
        if scope.repos.contains(where: { same($0.url.path) }) || same(scope.url.path) {
            return "your own checkout (\(path))"
        }
        return path
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        error = nil
        checkedOut = nil
        let proposal = TaskProposal(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: TaskBranch.slug(for: folder),
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source ?? .derived(reason: nil)
        )
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let repos = repos
        Task {
            do {
                try await model.createTask(proposal, prompt: request, driverID: driverID, in: scope.id, repos: repos,
                                           startPoint: startPoint, runSetup: runSetup)
                dismiss()
            } catch TaskError.branchAlreadyCheckedOut(_, let busy, let path) {
                checkedOut = (busy, holder(of: path))
            } catch {
                self.error = String(describing: error)
            }
            isCreating = false
        }
    }
}
