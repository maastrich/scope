import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// ⌘⇧T: name → live slug and `scope/<slug>` branch preview, a repo checklist for multi-repo scopes
/// (a repo scope sandboxes the scope itself), then Create. Worktrees are created off the main actor;
/// the sheet shows a spinner meanwhile. Errors show inline and in the Problem Center.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: ScopeState

    @State private var name = ""
    @State private var selectedRepos: Set<String> = []
    @State private var isCreating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Auth refresh"))
                        .focused($nameFocused)
                        .onSubmit { if canCreate { create() } }
                    LabeledContent("Branch") {
                        Text(branchPreview)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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

            // Standard trailing button row.
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating \(repoCount) \(repoCount == 1 ? "sandbox" : "sandboxes") — fetching origin…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 480)
        .frame(minHeight: 260, maxHeight: 520)
        .onAppear {
            nameFocused = true
            if !isRepoScope, scope.repos.count == 1, let only = scope.repos.first {
                selectedRepos = [only.id]
            }
        }
    }

    private var isRepoScope: Bool {
        scope.kind == .repo || scope.repos.contains { $0.id.isEmpty }
    }

    private var slug: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "…" : TaskBranch.slug(for: trimmed)
    }

    private var branchPreview: String {
        "\(model.config.preferences.branchPrefix)/\(slug)"
    }

    private var sandboxPath: String {
        "\(model.env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug).path)/\(slug)"
    }

    private var repoCount: Int { isRepoScope ? 1 : selectedRepos.count }

    private var canCreate: Bool {
        !isCreating && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repoCount > 0
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { selectedRepos.contains(repo) },
            set: { on in if on { selectedRepos.insert(repo) } else { selectedRepos.remove(repo) } }
        )
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        error = nil
        let repos = isRepoScope ? ["."] : scope.repos.map(\.id).filter { selectedRepos.contains($0) }
        let taskName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.createTask(name: taskName, in: scope.id, repos: repos)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
            isCreating = false
        }
    }
}
