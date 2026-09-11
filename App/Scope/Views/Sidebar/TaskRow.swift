import SwiftUI
import ScopeCore
import ScopeTasks

/// Sidebar row for a task: one status glyph, the name, `+N −M`.
///
/// The glyph is `TaskStatus.resolve` — the single most pressing thing about the task, a thread waiting on you
/// first — and replaces what used to be a branch icon, a PR chip and a trailing state dot that each said part of
/// it. The name takes the whole width: the hover controls (archive, menu) are drawn over the trailing counts,
/// which fade out under them, instead of holding a gutter open when the pointer is elsewhere. The rest — branch,
/// repositories, pull request, prompt — is in the hover card.
///
/// A task with one thread is one row: selecting it already shows that thread's terminal, so a nested row with the
/// same title only doubled the list. The chevron and the nested rows come with the second thread; until then the
/// thread's own menu items are in this row's context menu.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskState
    @State private var isHovered = false
    @State private var showsCard = false
    @State private var cardDelay: Task<Void, Never>?

    /// Long enough that sweeping the pointer down the list opens nothing.
    private static let cardDelay: Duration = .milliseconds(700)

    var body: some View {
        let threads = model.threads(in: task.id)
        let facts = model.taskFacts(for: task)
        let status = TaskStatus.resolve(facts)
        HStack(spacing: 7) {
            disclosure(shown: threads.count > 1)

            TaskStatusGlyph(status: status)

            Text(task.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            DeltaCounts(additions: task.totalAdditions, deletions: task.totalDeletions)
                .lineLimit(1)
        }
        .trailingFade(isHovered, width: SidebarMetrics.hoverControlsWidth)
        .overlay(alignment: .trailing) {
            if isHovered { hoverControls }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .popover(isPresented: $showsCard, arrowEdge: .trailing) {
            TaskHoverCard(task: task, status: status, facts: facts)
        }
        .contextMenu { TaskContextMenu(task: task) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.name)
        .accessibilityValue(TaskStatus.summary(status, facts: facts))
        .accessibilityActions {
            if threads.count > 1 {
                Button(task.isExpanded ? "Collapse" : "Expand") { task.isExpanded.toggle() }
            }
            Button("Archive") { Task { await model.archiveTask(task.id) } }
        }
    }

    /// The chevron, or its empty slot: task glyphs stay in one column whether or not a task has nested rows.
    @ViewBuilder
    private func disclosure(shown: Bool) -> some View {
        if shown {
            Button {
                task.isExpanded.toggle()
            } label: {
                Image(systemName: task.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.iconTight)
            .help(task.isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private var hoverControls: some View {
        HStack(spacing: 2) {
            Button {
                Task { await model.archiveTask(task.id) }
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.iconTight)
            .help("Archive: remove the sandboxes, keep the branch")

            Menu {
                TaskContextMenu(task: task)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .transition(.opacity)
    }

    private func hover(_ hovering: Bool) {
        if reduceMotion {
            isHovered = hovering
        } else {
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        cardDelay?.cancel()
        guard hovering else {
            showsCard = false
            return
        }
        cardDelay = Task {
            try? await Task.sleep(for: Self.cardDelay)
            guard !Task.isCancelled else { return }
            showsCard = true
        }
    }
}

/// Context menu of a task row and of its hover "…" menu. A task with a single thread shows that thread's own
/// items too, since the thread has no row of its own to right-click.
struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        let threads = model.threads(in: task.id)
        if threads.count == 1, let only = threads.first {
            ThreadMenuItems(session: only)
            Divider()
        }
        Button("New Thread in Task") {
            Task { _ = await model.newThread(in: task.scopeID, taskID: task.id) }
        }
        Menu("New Thread With Driver") {
            ForEach(model.drivers.profiles) { profile in
                Button(profile.name) {
                    Task { _ = await model.newThread(in: task.scopeID, driverID: profile.id, taskID: task.id) }
                }
            }
        }
        Divider()
        let candidates = model.candidateRepos(for: task)
        Menu("Add Repo…") {
            ForEach(candidates) { repo in
                Button(repo.id) {
                    Task { await model.addRepo(repo.id, to: task.id) }
                }
            }
        }
        .disabled(candidates.isEmpty)
        Button("Open Task in Editor") {
            model.openTaskInEditor(task)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        Button("See Delta") {
            model.selection = .task(task.id)
            model.inspectorTab = .delta
            model.inspectorShown = true
        }
        if let pr = task.record.pullRequest {
            Button("Open Pull Request \(pr.label) on GitHub") { model.openOnGitHub(pr.url) }
        }
        Divider()
        Button("Reveal in Finder") {
            Reveal.inFinder(task.record.rootURL)
        }
        Button("Copy Task Root Path") {
            Pasteboard.copyPath(task.record.rootURL)
        }
        Button("Refresh") {
            task.refresh()
        }
        Divider()
        Button("Archive") {
            Task { await model.archiveTask(task.id) }
        }
        Button("Close Task…", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: false) }
        }
        Button("Close Task and Delete Branch…", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: true) }
        }
    }
}
