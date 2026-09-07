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
        VStack(alignment: .leading, spacing: 14) {
            Text("New Task in \(scope.name)")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Task name", text: $name, prompt: Text("e.g. Auth refresh"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { if canCreate { create() } }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(branchPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(model.env.tasks.scopeSandboxesURL(scopeSlug: scope.declaration.slug).path)/\(slug)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isRepoScope {
                Label("Sandbox: a worktree of \(scope.name) on the task branch.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repositories")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if scope.repos.isEmpty {
                        Text(scope.discovery == .scanning ? "Scanning…" : "No git repository found in this scope.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(scope.repos) { repo in
                                    Toggle(isOn: binding(for: repo.id)) {
                                        HStack(spacing: 6) {
                                            Text(repo.id)
                                                .font(.system(size: 12))
                                            if let branch = repo.branchLabel {
                                                Text(branch)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating \(repoCount) \(repoCount == 1 ? "sandbox" : "sandboxes") — fetching origin…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
        }
        .padding(20)
        .frame(width: 460)
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
