import SwiftUI
import ScopeCore

/// The sidebar: a `List(selection:)` of `SidebarItem`s — one scope row per declared scope, then (when the
/// scope is expanded) its repo rows and its thread rows — with the New Thread / New Task footer.
/// Expansion is driven by `ScopeState.isExpanded` (persisted by the model) rather than `DisclosureGroup`,
/// so indentation and chevrons follow the design spec exactly. The filter field at the top (⌥⌘F, Esc clears)
/// keeps the scope / task / thread rows whose name fuzzy-matches (subsequence); repo rows follow their scope.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var scopeBeingRenamed: ScopeState?
    @State private var renameText = ""
    @State private var footerWidth: CGFloat = 0
    @FocusState private var filterFocused: Bool

    /// Below this width the footer buttons drop their titles.
    private static let footerTitleThreshold: CGFloat = 230

    private var filter: String { model.searchUI.sidebarFilter.trimmingCharacters(in: .whitespaces) }
    private var isFiltering: Bool { !filter.isEmpty }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.scopes.isEmpty {
                SidebarEmptyView()
            } else {
                List(selection: $model.selection) {
                    Section {
                        ForEach(visibleScopes) { scope in
                            ScopeRow(scope: scope) { scope in
                                renameText = scope.name
                                scopeBeingRenamed = scope
                            }
                            .tag(SidebarItem.scope(scope.id))
                            if scope.isExpanded || isFiltering {
                                scopeChildren(scope)
                            }
                        }
                        .onMove { offsets, destination in
                            guard !isFiltering else { return }
                            model.moveScopes(fromOffsets: offsets, toOffset: destination)
                        }
                        if isFiltering, visibleScopes.isEmpty {
                            Text("Nothing matches “\(filter)”")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .selectionDisabled()
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
                .safeAreaInset(edge: .top, spacing: 0) {
                    filterField
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .onChange(of: model.searchUI.sidebarFilterFocusTick) { filterFocused = true }
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

    // MARK: Filter

    private var filterField: some View {
        @Bindable var ui = model.searchUI
        return HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Filter", text: $ui.sidebarFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .accessibilityLabel("Filter sidebar")
                .onKeyPress(.escape) {
                    model.searchUI.sidebarFilter = ""
                    filterFocused = false
                    AppDelegate.refocusTerminal()
                    return .handled
                }
            if isFiltering {
                Button {
                    model.searchUI.sidebarFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            } else {
                Text("⌥⌘F")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filterFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1)))
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
        .help("Filter scopes, tasks and threads by name (⌥⌘F, Esc clears)")
    }

    private func matches(_ name: String) -> Bool {
        !isFiltering || PaletteModel.fuzzyScore(filter, in: name) != nil
    }

    private func visibleTasks(in scope: ScopeState) -> [TaskState] {
        model.tasks(in: scope.id).filter { task in
            matches(task.name) || model.threads(in: task.id).contains { matches($0.title) }
        }
    }

    private func visibleThreads(in task: TaskState) -> [ThreadSession] {
        let threads = model.threads(in: task.id)
        guard isFiltering, !matches(task.name) else { return threads }
        return threads.filter { matches($0.title) }
    }

    private func visibleScopeThreads(in scope: ScopeState) -> [ThreadSession] {
        model.scopeLevelThreads(in: scope.id).filter { matches($0.title) }
    }

    private var visibleScopes: [ScopeState] {
        guard isFiltering else { return model.scopes }
        return model.scopes.filter { scope in
            matches(scope.name) || !visibleTasks(in: scope).isEmpty || !visibleScopeThreads(in: scope).isEmpty
        }
    }

    /// Repo rows, the "no repositories" hint, then the root thread rows of one expanded scope.
    @ViewBuilder
    private func scopeChildren(_ scope: ScopeState) -> some View {
        if !isFiltering || matches(scope.name) {
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
        }
        ForEach(visibleTasks(in: scope)) { task in
            TaskRow(task: task)
                .tag(SidebarItem.task(task.id))
            if model.selection == .task(task.id), !isFiltering {
                TaskDetailView(task: task)
            }
            if task.isExpanded || isFiltering {
                ForEach(visibleThreads(in: task)) { session in
                    ThreadRow(session: session, depth: 2)
                        .tag(SidebarItem.thread(session.id))
                }
            }
        }
        ForEach(visibleScopeThreads(in: scope)) { session in
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

    /// Two equal-width buttons: New Thread (⌘T, in the current task when one is selected) and New Task (⇧⌘T).
    /// Titles are shown down to `footerTitleThreshold` points, icons only below (measured, so the text is
    /// never clipped mid-word).
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if footerWidth >= Self.footerTitleThreshold {
                    footerButtons(.titleAndIcon)
                } else {
                    footerButtons(.iconOnly)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .controlSize(.regular)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { footerWidth = $0 }
        }
        .background(.bar)
    }

    private func footerButtons(_ style: some LabelStyle) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.newThreadInCurrentContext() }
            } label: {
                Label("New Thread", systemImage: "plus")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.currentScope == nil)
            .help("New Thread (⌘T) \(model.newThreadTargetDescription ?? "")".trimmingCharacters(in: .whitespaces))
            .accessibilityLabel("New Thread")

            Button {
                model.presentNewTask()
            } label: {
                Label("New Task", systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.currentScope == nil || model.currentScope?.kind == .missing)
            .help("New Task (⇧⌘T)")
            .accessibilityLabel("New Task")
        }
        .labelStyle(style)
    }
}
