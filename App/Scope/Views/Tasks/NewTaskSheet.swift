import SwiftUI
import ScopeCore
import ScopeDrivers
import ScopeGit
import ScopeTasks

/// ⌘⇧T, two steps. **Prompt**: what the agent should do, the driver, the repos (a repo scope sandboxes the
/// scope itself). **Continue** derives a title / branch / folder from the prompt at once (level 0) and, when
/// the driver has a headless mode, asks it for a branch that follows the repo's own convention (level 1,
/// replaces the fields when it answers, cancellable). **Create** makes the sandboxes, then opens the first
/// thread with the driver and the prompt. Errors show inline and in the Problem Center.
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
    @State private var title = ""
    @State private var branch = ""
    @State private var folder = ""
    @State private var source: TaskProposal.Source?
    @State private var fieldsEdited = false
    @State private var proposing: Task<Void, Never>?
    @State private var isCreating = false
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
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

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

        if isRepoScope {
            Section {
                Label("Sandbox: a worktree of \(scope.name) on the task branch.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                if scope.repos.isEmpty {
                    Text(scope.discovery == .scanning ? "Scanning…" : "No git repository found in this scope.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scope.repos) { repo in
                        Toggle(isOn: binding(for: repo.id)) {
                            HStack(spacing: 6) {
                                Text(repo.id)
                                    .font(.system(size: 12))
                                if let branch = repo.branchLabel {
                                    Text(branch)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    if scope.repos.count > 1 {
                        Button("All") { selectedRepos = Set(scope.repos.map(\.id)) }
                        Button("None") { selectedRepos = [] }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            } footer: {
                if !scope.repos.isEmpty, selectedRepos.isEmpty {
                    Text("Pick at least one repository.")
                }
            }
        }
    }

    // MARK: Step 2 — proposal

    @ViewBuilder private var proposalSections: some View {
        Section {
            TextField("Title", text: $title)
                .focused($titleFocused)
                .onChange(of: title) { fieldsEdited = true }
            TextField("Branch", text: $branch)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .onChange(of: branch) { fieldsEdited = true }
            TextField("Folder", text: $folder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .onChange(of: folder) { fieldsEdited = true }
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
                    Text("Asking \(selectedProfile?.name ?? "the driver") for a branch name…")
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
        if profile.headless?.isEmpty == false {
            return "\(profile.name) proposes the branch name from the repo's existing conventions, then opens the first thread."
        }
        return "\(profile.name) has no headless mode: the branch name is derived from the prompt."
    }

    private var sourceCaption: String {
        switch source {
        case .driver(let name): "Suggested by \(name)."
        case .derived(let reason?): "Derived from the prompt — \(reason)"
        case .derived(nil), nil: "Derived from the prompt."
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
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repoCount > 0
    }

    private var canCreate: Bool {
        !isCreating && proposing == nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { selectedRepos.contains(repo) },
            set: { on in if on { selectedRepos.insert(repo) } else { selectedRepos.remove(repo) } }
        )
    }

    // MARK: Actions

    private func continueToProposal() {
        guard canContinue else { return }
        error = nil
        fieldsEdited = false
        step = .proposal
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let repos = repos
        let scopeID = scope.id
        let driver = driverID
        proposing?.cancel()
        proposing = Task {
            let evidence = await model.branchEvidence(for: repos, in: scopeID)
            guard !Task.isCancelled else { return }
            self.evidence = evidence
            apply(model.fallbackProposal(prompt: request, evidence: evidence, in: scopeID), force: true)
            titleFocused = true
            if model.drivers.profile(id: driver)?.headless?.isEmpty == false {
                let proposal = await model.proposeTask(prompt: request, driverID: driver, repos: repos, evidence: evidence, in: scopeID)
                guard !Task.isCancelled else { return }
                apply(proposal, force: false)
            }
            proposing = nil
        }
    }

    /// Fills the fields; a level-1 answer does not clobber what the user already typed.
    private func apply(_ proposal: TaskProposal, force: Bool) {
        if !force, fieldsEdited {
            source = proposal.source
            return
        }
        title = proposal.title
        branch = proposal.branch
        folder = proposal.slug
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

    private func create() {
        guard canCreate else { return }
        isCreating = true
        error = nil
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
                try await model.createTask(proposal, prompt: request, driverID: driverID, in: scope.id, repos: repos)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
            isCreating = false
        }
    }
}
