import SwiftUI
import ScopeCore

/// The sidebar: a `List(selection:)` of `SidebarItem`s — one scope row per declared scope, then (when the
/// scope is expanded) its repo rows and its thread rows — with the New Thread / New Task footer.
/// Expansion is driven by `ScopeState.isExpanded` (persisted by the model) rather than `DisclosureGroup`,
/// so indentation and chevrons follow the design spec exactly.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var scopeBeingRenamed: ScopeState?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        Group {
            if model.scopes.isEmpty {
                SidebarEmptyView()
            } else {
                List(selection: $model.selection) {
                    Section {
                        ForEach(model.scopes) { scope in
                            ScopeRow(scope: scope) { scope in
                                renameText = scope.name
                                scopeBeingRenamed = scope
                            }
                            .tag(SidebarItem.scope(scope.id))
                            if scope.isExpanded {
                                scopeChildren(scope)
                            }
                        }
                        .onMove { offsets, destination in
                            model.moveScopes(fromOffsets: offsets, toOffset: destination)
                        }
                    } header: {
                        Text("Scopes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.sidebar)
                .folderDropTarget { urls in
                    Task { await model.addScopes(urls) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .alert("Rename Scope", isPresented: isRenaming, presenting: scopeBeingRenamed) { scope in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    model.renameScope(scope.id, name: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { scope in
            Text("The folder \(scope.url.path) is not renamed; only the sidebar label changes.")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { scopeBeingRenamed != nil },
            set: { presented in
                if !presented { scopeBeingRenamed = nil }
            }
        )
    }

    /// Repo rows, the "no repositories" hint, then the root thread rows of one expanded scope.
    @ViewBuilder
    private func scopeChildren(_ scope: ScopeState) -> some View {
        ForEach(scope.repos) { repo in
            RepoRow(scope: scope, repo: repo)
                .tag(SidebarItem.repo(scope.id, relativePath: repo.id))
        }
        if scope.repos.isEmpty, scope.discovery != .scanning, scope.kind != .missing {
            noReposRow(scope)
        }
        if case .failed(let message) = scope.discovery {
            scanFailedRow(scope, message: message)
        }
        ForEach(model.tasks(in: scope.id)) { task in
            TaskRow(task: task)
                .tag(SidebarItem.task(task.id))
            if model.selection == .task(task.id) {
                TaskDetailView(task: task)
            }
            if task.isExpanded {
                ForEach(model.threads(in: task.id)) { session in
                    ThreadRow(session: session, depth: 2)
                        .tag(SidebarItem.thread(session.id))
                }
            }
        }
        ForEach(model.scopeLevelThreads(in: scope.id)) { session in
            ThreadRow(session: session)
                .tag(SidebarItem.thread(session.id))
        }
    }

    private func noReposRow(_ scope: ScopeState) -> some View {
        HStack(spacing: 6) {
            Text("No git repositories at depth \(scope.declaration.discoveryDepth)")
                .lineLimit(2)
            Spacer(minLength: 0)
            if scope.declaration.discoveryDepth < 4 {
                Button("Search deeper") {
                    model.setDiscoveryDepth(scope.declaration.discoveryDepth + 1, for: scope.id)
                }
                .controlSize(.mini)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.leading, 16)
        .selectionDisabled()
    }

    private func scanFailedRow(_ scope: ScopeState, message: String) -> some View {
        HStack(spacing: 6) {
            Text("scan failed")
                .foregroundStyle(Color(nsColor: .systemRed))
            Spacer(minLength: 0)
            Button("Retry") {
                model.refreshScope(scope.id)
            }
            .controlSize(.mini)
        }
        .font(.system(size: 11))
        .help(message)
        .padding(.leading, 16)
        .selectionDisabled()
    }

    /// Two equal-width buttons: New Thread (⌘T, in the current task when one is selected) and New Task (⌘⇧T).
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    if let scope = model.currentScope {
                        Task { _ = await model.newThread(in: scope.id, taskID: model.currentTask?.id) }
                    }
                } label: {
                    Label("New Thread", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.currentScope == nil)
                .help("New Thread (⌘T)")

                Button {
                    model.presentNewTask()
                } label: {
                    Label("New Task", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.currentScope == nil || model.currentScope?.kind == .missing)
                .help("New Task (⌘⇧T)")
            }
            .font(.system(size: 12, weight: .medium))
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
