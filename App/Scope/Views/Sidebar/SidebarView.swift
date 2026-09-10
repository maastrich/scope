import AppKit
import SwiftUI
import ScopeCore

/// The sidebar: the work of the current scope. A header row with the scope name as a switcher (`ScopeSwitcher`),
/// the filter field (⌥⌘F, Esc clears; fuzzy subsequence on task / thread / repo names), then a `List(selection:)`
/// of `SidebarItem`s as **one tree** — a **Loose threads** group holding the threads that belong to no task, then
/// the tasks with their own threads nested — followed by **Repositories** (collapsed by default,
/// `ScopeState.reposShown`), which is a launcher rather than work. The New Thread / New Task footer closes it. Other scopes are reached through the switcher, ⌘K or ⌘O.
/// It is the only thread switcher: picking a thread hands the keyboard straight back to its terminal.
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
            } else if let scope = model.currentScope {
                List(selection: $model.selection) {
                    workSection(scope)
                    repositoriesSection(scope)
                }
                .listStyle(.sidebar)
                .folderDropTarget { urls in
                    Task { await model.addScopes(urls) }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ScopeSwitcher(scope: scope) { scope in
                            renameText = scope.name
                            scopeBeingRenamed = scope
                        }
                        filterField
                        if model.config.preferences.attentionCounter == .sidebar {
                            AttentionBanner()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .onChange(of: model.searchUI.sidebarFilterFocusTick) { filterFocused = true }
        // Picking a thread here is picking where to type: the List keeps its highlight, the terminal takes
        // the keyboard (the command palette already behaves this way).
        //
        // Both changes matter, and neither implies the other. Selecting a task moves the live thread without
        // touching the selected row's kind; clicking a row that already shows the live thread moves the row
        // without touching the thread — and both used to leave the keyboard in the list.
        .onChange(of: model.selectedThreadID) { _, id in
            guard id != nil else { return }
            focusTerminalAfterSelection()
        }
        .onChange(of: model.selection) { _, item in
            switch item {
            // A task row shows the terminal of its live thread, so picking one is picking where to type too.
            case .thread, .task: focusTerminalAfterSelection()
            // A scope or repo row shows an empty view: there is no terminal to hand the keyboard to.
            case .scope, .repo, nil: break
            }
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

    /// Hands the keyboard to the visible terminal, one turn later: the thread's `TerminalHost` has to be in
    /// the window before it can hold focus. Does nothing while the filter field has the keyboard — typing a
    /// filter must not be interrupted by the terminal stealing it back — nor when no thread is live, where
    /// the scene shows an empty view and there is nothing to focus.
    private func focusTerminalAfterSelection() {
        guard !filterFocused, model.selectedThreadID != nil else { return }
        DispatchQueue.main.async { AppDelegate.refocusTerminal() }
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
        .padding(EdgeInsets(top: 2, leading: 10, bottom: 4, trailing: 10))
        .help("Filter tasks, threads and repositories by name (⌥⌘F, Esc clears)")
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

    private func visibleRepos(in scope: ScopeState) -> [RepoState] {
        scope.repos.filter { matches($0.shortName) }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if let count {
                Text("· \(count)")
                    .foregroundStyle(.quaternary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .selectionDisabled()
    }

    // MARK: Sections

    /// The work of the scope as one tree, with no section header: the **Loose threads** group first — the threads
    /// that belong to no task, which used to live in a Threads section of their own — then the tasks with their
    /// own threads nested. One shape, one depth, one place to look for a thread.
    private func workSection(_ scope: ScopeState) -> some View {
        Section {
            looseThreadsGroup(scope)

            let tasks = visibleTasks(in: scope)
            ForEach(tasks) { task in
                TaskRow(task: task)
                    .tag(SidebarItem.task(task.id))
                if task.isExpanded || isFiltering {
                    ForEach(visibleThreads(in: task)) { session in
                        ThreadRow(session: session, depth: 1)
                            .tag(SidebarItem.thread(session.id))
                    }
                }
            }
            if tasks.isEmpty {
                hintRow(isFiltering ? "No task matches “\(filter)”" : (scope.kind == .missing ? "Scope folder is missing" : "No task yet — ⇧⌘T"))
            }
        }
    }

    /// The scope-level and repo-base threads, under one group row at the depth of a task. The group is skipped
    /// entirely when the scope has none: an empty parent is worse than no parent.
    @ViewBuilder
    private func looseThreadsGroup(_ scope: ScopeState) -> some View {
        let threads = visibleScopeThreads(in: scope)
        if !threads.isEmpty {
            LooseThreadsRow(scope: scope, count: threads.count)
                .selectionDisabled()
            if scope.looseThreadsShown || isFiltering {
                ForEach(threads) { session in
                    ThreadRow(session: session, depth: 1)
                        .tag(SidebarItem.thread(session.id))
                }
            }
        }
    }

    /// The discovered repositories, collapsed by default (`ScopeState.reposShown`, persisted per scope); a
    /// filter that matches repo names shows them regardless.
    private func repositoriesSection(_ scope: ScopeState) -> some View {
        let repos = visibleRepos(in: scope)
        let forced = isFiltering && !repos.isEmpty
        return Section(isExpanded: Binding(
            get: { scope.reposShown || forced },
            set: { shown in
                scope.reposShown = shown
                model.expansionChanged()
            }
        )) {
            ForEach(repos) { repo in
                RepoRow(scope: scope, repo: repo)
                    .tag(SidebarItem.repo(scope.id, relativePath: repo.id))
            }
            if isFiltering, repos.isEmpty, !scope.repos.isEmpty {
                hintRow("No repository matches “\(filter)”")
            }
            if scope.repos.isEmpty, scope.discovery != .scanning, scope.kind != .missing {
                noReposRow(scope)
            }
            if case .failed(let message) = scope.discovery {
                scanFailedRow(scope, message: message)
            }
        } header: {
            sectionHeader("Repositories", count: scope.repos.count)
                .accessibilityLabel("Repositories, \(scope.repos.count)")
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
        .selectionDisabled()
    }

    /// Two equal-width buttons: New Thread — always a loose one, even with a task selected (a thread inside a
    /// task comes from the task's context menu) — and New Task (⇧⌘T).
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
            // A `Menu` would draw its chrome around its label and come out half the width of its neighbour,
            // so the driver choice hangs off the right-click menu of an ordinary button instead.
            Button {
                Task { await model.newLooseThread() }
            } label: {
                Label("New Thread", systemImage: "plus")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .contextMenu {
                ForEach(model.drivers.profiles) { profile in
                    Button(profile.name) {
                        Task { await model.newLooseThread(driverID: profile.id) }
                    }
                }
            }
            .disabled(model.currentScope == nil)
            .help("New loose thread \(model.looseThreadTargetDescription ?? "") — right-click to choose a driver; "
                  + "a thread inside a task is on the task's own menu")
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
