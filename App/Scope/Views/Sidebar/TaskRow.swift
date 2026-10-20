import SwiftUI
import ScopeControl
import ScopeCore
import ScopeTasks

/// Sidebar row for a task: the name, and one mark at the end of the row — the state dot of its threads, or a
/// `merged` chip (`SidebarTaskRowPolicy`).
///
/// The trailing dot is the rule every sidebar row follows: the agents' state, in the shapes `StateDot` gives it, at
/// the end of the row — a thread's own, the most urgent of a group's or a task's threads — so the eye can run down
/// one column and find every thread that wants it. A task with no thread keeps the column blank. No status glyph
/// in front of the name any more, and no `+N −M` after it: the glyph said what the dot and the group already say,
/// and at the sidebar's width the counts truncated the name. Both live on in the hover card.
///
/// One line by default; a second while the task is waiting for you or working, saying what its agent is doing.
/// The name takes the whole width: the hover controls (editor, menu) are drawn over the end of the name,
/// left of the dot, instead of holding a gutter open when the pointer is elsewhere. The rest — branch, repositories,
/// pull request, counts, prompt — is in the hover card.
///
/// A task with one thread is one row: selecting it already shows that thread's terminal, so a nested row with the
/// same title only doubled the list. The chevron and the nested rows come with the second thread; until then the
/// thread's own menu items are in this row's context menu.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskState
    /// 1 under a topic's row, like a thread under **Loose threads**.
    var depth = 0
    @State private var isHovered = false
    @State private var showsCard = false
    @State private var cardDelay: Task<Void, Never>?
    /// The merged chip's width, so the hover controls leave it clear the way they leave the dot clear.
    @State private var chipWidth: CGFloat = 0

    /// Long enough that sweeping the pointer down the list opens nothing.
    private static let cardDelay: Duration = .milliseconds(700)

    var body: some View {
        let threads = model.threads(in: task.id)
        let facts = model.taskFacts(for: task)
        let status = TaskStatus.resolve(facts)
        let secondLine = SidebarTaskRowPolicy.showsSecondLine(rows: model.config.preferences.sidebarRows, status: status)
        let trailing = SidebarTaskRowPolicy.trailing(status: status, secondLine: secondLine)
        HStack(spacing: SidebarMetrics.spacing) {
            SidebarDisclosure(isExpanded: threads.count > 1 ? task.isExpanded : nil) {
                task.isExpanded.toggle()
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(task.name)
                        .font(.scopeBody)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // On a one-line row, what would open the second line follows the name instead: `· idle 4d`.
                    if !secondLine {
                        if let mission = task.record.mission, !mission.milestones.isEmpty {
                            Text(" · \(mission.progress.reached)/\(mission.progress.total)")
                                .font(.scopeCaption.monospacedDigit())
                                .foregroundStyle(Ink.tertiary)
                                .fixedSize()
                                .help(mission.caption)
                        }
                        TaskDormancyCaption(task: task, leading: true)
                    }
                }
                if secondLine {
                    HStack(spacing: 0) {
                        TaskDormancyCaption(task: task, separated: true)
                        if let mission = task.record.mission, !mission.milestones.isEmpty {
                            Text("\(mission.progress.reached)/\(mission.progress.total) · ")
                                .font(.scopeCaption.monospacedDigit())
                                .foregroundStyle(Ink.tertiary)
                                .help(mission.caption)
                        }
                        if let parent = linkedParent(threads) {
                            ParentTaskLink(parent: parent)
                            Text(" · ")
                                .font(.scopeCaption)
                                .foregroundStyle(Ink.tertiary)
                        }
                        if let headline = activityHeadline(threads) {
                            ThreadActivityCaption(headline: headline)
                        } else {
                            Text(TaskStatus.summary(status, facts: facts))
                                .font(.scopeCaption)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            switch trailing {
            case .mergedChip:
                SidebarMergedChip()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
            case .stateDot:
                SidebarStateDot(
                    state: ThreadState.mostUrgent(threads.map(\.displayState)),
                    pulses: threads.contains(where: \.isWorking)
                )
            }
        }
        .sidebarHoverControls(isHovered, kept: trailing == .mergedChip ? chipWidth + SidebarMetrics.spacing : SidebarMetrics.keptUnderHover) {
            hoverControls
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: secondLine))
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .popover(isPresented: $showsCard, arrowEdge: .trailing) {
            TaskHoverCard(task: task, status: status, facts: facts)
        }
        .sidebarRow(selected: isListSelected)
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

    /// The row the List highlights.
    private var isListSelected: Bool {
        model.selection == .task(task.id)
    }

    /// In the tree, a quiet task started from another one names it at the start of its second line. While one of
    /// its agents works or waits, what it is doing needs the whole width, and the parent stays one hover card or
    /// right-click away. By state, rows move with what they are doing and the hover card says where a task came from.
    private func linkedParent(_ threads: [ThreadSession]) -> TaskState? {
        guard model.config.preferences.sidebarArrangement == .tree,
              !threads.contains(where: { $0.displayState == .running || $0.displayState.needsAttention })
        else { return nil }
        return model.parentTask(of: task)
    }

    /// A one-thread task is that thread's row too: while its agent works, waits or has an unread result, the
    /// second line says what it is doing, as the thread's row would. Once read, the task's own status says more.
    private func activityHeadline(_ threads: [ThreadSession]) -> ThreadActivityHeadline? {
        guard threads.count == 1, let only = threads.first else { return nil }
        let state = only.displayState
        guard state == .running || state.needsAttention || state.isUnreadResult else { return nil }
        return only.activityHeadline(model.config.preferences.finishedThreadLine)
    }

    private var hoverControls: some View {
        HStack(spacing: 2) {
            Button {
                model.openTaskInEditor(task)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.iconTight)
            .help("Open Task in Editor (⇧⌘E)")
            .accessibilityLabel("Open \(task.name) in Editor")
            .usageID("sidebar.task.open-editor", label: "Open task in editor (row hover)")

            // Archive is in the menu, not under the pointer: a row's hover controls are what a stray click lands on.
            ScopeIconMenu(systemImage: "ellipsis", title: "More") {
                TaskContextMenu(task: task)
            }
            .usageID("sidebar.task.more", label: "Task row “…” menu")
        }
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
            DriverMenuItems { driver, chosen in
                Task { _ = await model.newThread(in: task.scopeID, driverID: driver, taskID: task.id, model: chosen) }
            }
        }
        // One item per branch added beside the task's own: the thread starts in that worktree.
        ForEach(task.activeSandboxes.filter(\.isSecondary), id: \.sandboxKey) { sandbox in
            Button("New Thread on \(sandbox.branch)") {
                Task { _ = await model.newThread(in: task.scopeID, taskID: task.id, branch: sandbox.branch) }
            }
        }
        Divider()
        TopicMenu(tasks: [task])
        DelegationMenuItems(task: task)
        let candidates = model.candidateRepos(for: task)
        Menu("Add Repo…") {
            ForEach(candidates) { repo in
                Button(repo.id) {
                    Task { await model.addRepo(repo.id, to: task.id) }
                }
            }
        }
        .disabled(candidates.isEmpty)
        Button("Add Branch…") {
            model.addBranchFromUI(task)
        }
        .disabled(task.isArchived)
        let secondary = task.activeSandboxes.filter(\.isSecondary)
        Menu("Remove Branch") {
            ForEach(secondary, id: \.sandboxKey) { sandbox in
                Button(sandbox.sandboxLabel(scopeName: task.record.scopeName)) {
                    model.removeBranchFromUI(sandbox, of: task)
                }
            }
        }
        .disabled(secondary.isEmpty)
        Button("Open Task in Editor") {
            model.openTaskInEditor(task)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        Button("See Changes") {
            model.selection = .task(task.id)
            model.showInspector(.delta)
        }
        // One item per pull request: the repository named when the task spans several, since numbers repeat.
        ForEach(task.record.pullRequests) { pr in
            let where_ = task.record.pullRequests.count > 1 ? (model.repo(of: pr, in: task).map { "\($0.name) " } ?? "") : ""
            Button("Open Pull Request \(where_)\(pr.label) on GitHub") { model.openOnGitHub(pr.url) }
        }
        Divider()
        Button(model.lag(of: task)?.hasConflicts == true ? "Ask the Agent to Rebase on Main" : "Rebase on Main Now") {
            Task {
                Usage.click("sidebar.task.rebase-now", label: "Rebase on main now")
                _ = await model.rebaseNow(task)
            }
        }
        .disabled(task.record.holdBranch || model.pullRequests.followingMain.contains(task.id))
        Toggle("Don't Rebase Automatically", isOn: Binding(
            get: { task.record.holdBranch },
            set: { hold in
                Usage.click("sidebar.task.hold-branch", label: "Don't rebase automatically")
                Task { await model.setHoldBranch(hold, for: task) }
            }))
        if model.mayTryInCheckout(task) || !task.record.trying.isEmpty {
            TryInCheckoutMenuItems(task: task)
            Divider()
        }
        Button("Reveal in Finder") {
            Reveal.inFinder(task.record.rootURL)
        }
        // The name is how you refer to the task in a prompt; the slug is what `scope --task` takes.
        Button("Copy Task Name") {
            Pasteboard.copy(task.name)
        }
        Button("Copy Task Slug") {
            Pasteboard.copy(task.record.slug)
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
        Button("Close Task", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: false) }
        }
        Button("Close Task and Delete Branch", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: true) }
        }
    }
}

/// "Try in My Checkout", and while trying "Refresh My Checkout" / "Put My Checkout Back" (spec §4.5). Shown only when
/// the scope allows it, or a checkout is on the task and must be offered the way back whatever the setting says now.
struct TryInCheckoutMenuItems: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        if task.record.trying.isEmpty {
            Button("Try in My Checkout") {
                Usage.click("sidebar.task.try-in-checkout", label: "Try in my checkout")
                Task {
                    do { _ = try await model.tryInCheckout(task) } catch {
                        model.problems.error("Could not try \(task.name) in your checkout", detail: String(describing: error), scope: task.scopeID)
                    }
                }
            }
            .disabled(task.isArchived)
        } else {
            Button("Refresh My Checkout") {
                Usage.click("sidebar.task.try-refresh", label: "Refresh my checkout")
                Task {
                    do { _ = try await model.refreshTry(task) } catch {
                        model.problems.error("Could not refresh your checkout for \(task.name)", detail: String(describing: error), scope: task.scopeID)
                    }
                }
            }
            Button("Put My Checkout Back") {
                Usage.click("sidebar.task.try-put-back", label: "Put my checkout back")
                Task {
                    do { _ = try await model.putBack(task) } catch {
                        model.problems.error("Could not put your checkout back from \(task.name)", detail: String(describing: error), scope: task.scopeID)
                    }
                }
            }
        }
    }
}

/// The Topic submenu of a task: file it under a topic in use in its scope, a new one, or none. The tasks it started
/// that still share its topic come along (`AppModel.fileTasks`).
struct TopicMenu: View {
    @Environment(AppModel.self) private var model
    let tasks: [TaskState]

    var body: some View {
        if let first = tasks.first {
            let current = first.record.topic.map(TaskTopic.key)
            Menu("Topic") {
                ForEach(model.topics(in: first.scopeID), id: \.self) { topic in
                    Toggle(topic, isOn: Binding(
                        get: { current == TaskTopic.key(topic) },
                        set: { _ in Task { await model.fileTasks(tasks.map(\.id), underTopic: topic) } }
                    ))
                }
                if !model.topics(in: first.scopeID).isEmpty { Divider() }
                Button("New Topic…") {
                    guard let name = model.promptTopicName(title: "New Topic", current: nil, action: "File") else { return }
                    Task { await model.fileTasks(tasks.map(\.id), underTopic: name) }
                }
                if current != nil {
                    Button("Remove from Topic") {
                        Task { await model.fileTasks(tasks.map(\.id), underTopic: nil) }
                    }
                }
            }
        }
    }
}
