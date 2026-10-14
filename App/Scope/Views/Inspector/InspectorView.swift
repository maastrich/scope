import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// Right-hand inspector, about the selection alone: a 30 pt band naming the subject, level with the window toolbar,
/// then a column of collapsible sections — Task, Delta, Pull Request, Base, Files, Search, History — and, under
/// them, one viewer for the diff or the base file last opened.
///
/// Sections, not tabs: every one is always there, so the column says at a glance what exists, and a closed one costs
/// a line while its header keeps the essential (`+108 −12`, the branch and its lag, the checks). Several can be open;
/// the lists among them share the height and the sash between two open lists moves it. Which are open is kept per
/// scope (`ScopePlace`), separately with and without a task, and comes back as it was left.
///
/// The viewer is the departure from a plain VSCode sidebar. A diff or a file squeezed inside its own section shares
/// the height with every other open list and gets a sliver of a 380 pt panel; under the sections it keeps a real
/// share whatever is open above, and a Search result opens there without opening Files. It opens on a gesture — a
/// click on a file, `j` / `k`, a search jump — and ✕ gives its height back.
///
/// The loads every header needs run here rather than in the section bodies, so a closed section's summary is current.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    /// Height each block section's content asks for, reported by the section.
    @State private var naturals: [InspectorSection: Double] = [:]
    @FocusState private var viewerFocused: Bool

    private typealias Layout = InspectorSectionLayout
    /// A section is its header, its body and the 1 pt rule above it.
    private static let ruleHeight: Double = 1
    /// The least the viewer keeps when the sections above need room: its bar, its file header and a few lines.
    private static let viewerFloor: Double = 180
    /// How much of a block's content the sections claim from the viewer before the block scrolls instead.
    private static let blockFloorWithViewer: Double = 120

    var body: some View {
        VStack(spacing: 0) {
            InspectorSubjectBand()
            GeometryReader { geometry in
                column(total: Double(geometry.size.height))
            }
            if let task = model.currentTask, !model.review.comments.isEmpty || model.queuedDelivery(in: task) != nil {
                Divider()
                ReviewBar(task: task)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.ground)
        .task(id: model.baseSubject()?.repo.url) {
            guard let scope = model.currentScope, let repo = model.baseSubject()?.repo else { return }
            model.base.show(repo: repo)
            model.base.recent[scope.id] = GraphModel.key(for: repo)
        }
        .task(id: DeltaLoadKey(task: model.currentTask?.id, mode: model.delta.mode, tick: model.currentTask?.changeTick ?? 0)) {
            if let task = model.currentTask { await model.delta.load(task: task) }
        }
        .task(id: model.currentTask?.id) {
            guard let task = model.currentTask else { return }
            await model.review.show(task: task.id)
            // What notices the pull request a thread opened and binds it, and keeps its checks fresh.
            while !Task.isCancelled {
                await model.refreshTaskPullRequest(task)
                try? await Task.sleep(for: TaskSection.pullRequestRefreshInterval)
            }
        }
    }

    private struct DeltaLoadKey: Hashable {
        let task: TaskID?
        let mode: DeltaMode
        let tick: Int
    }

    // MARK: Column

    @ViewBuilder
    private func column(total: Double) -> some View {
        let items = InspectorSection.allCases.map { section in
            Layout.Item(section: section,
                        isOpen: model.isSectionAvailable(section) && model.isSectionOpen(section),
                        natural: naturals[section] ?? 0)
        }
        let chrome = Double(items.count) * (Layout.headerHeight + Self.ruleHeight)
        let fillOpen = items.contains { $0.isOpen && $0.section.fills }
        let viewer = resolvedViewer
        let stack: Double = {
            guard viewer != nil else { return total }
            if model.inspector.viewerMaximized { return 0 }
            if fillOpen {
                // The viewer gives way before the sections overflow: a header pushed out of sight is a section
                // nobody knows is there.
                let open = items.filter(\.isOpen)
                let least = chrome + open.reduce(0) {
                    $0 + ($1.section.fills ? Layout.minimumFill : min($1.natural, Self.blockFloorWithViewer))
                }
                let shared = total * (1 - model.inspector.viewerShare)
                return max(shared, min(least, total - Self.viewerFloor)).rounded()
            }
            // Nothing above stretches: the sections take what they need and the viewer the rest.
            let blocks = items.filter { $0.isOpen }.reduce(0) { $0 + $1.natural }
            return min(chrome + blocks, total * 0.8).rounded()
        }()
        let heights = Layout.bodyHeights(available: stack - Double(items.count) * Self.ruleHeight, items: items,
                                         weights: model.inspector.weights)
        let content = chrome + heights.values.reduce(0, +)
        VStack(spacing: 0) {
            if stack > 0 {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(InspectorSection.allCases, id: \.self) { section in
                            sectionView(section, heights: heights)
                        }
                    }
                }
                .scrollDisabled(content <= stack + 0.5)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: stack)
            }
            if let viewer {
                viewerPane(viewer, total: total, draggable: fillOpen && !model.inspector.viewerMaximized)
                    .frame(height: max(0, total - stack))
            }
        }
        .frame(height: total, alignment: .top)
    }

    @ViewBuilder
    private func sectionView(_ section: InspectorSection, heights: [InspectorSection: Double]) -> some View {
        let height = heights[section]
        switch section {
        case .task:
            TaskSection(bodyHeight: height, onNatural: natural(for: .task))
        case .delta:
            DeltaSection(bodyHeight: height, sash: sash(above: .delta, heights: heights))
        case .pullRequest:
            PullRequestSection(bodyHeight: height, onNatural: natural(for: .pullRequest))
        case .base:
            BaseSection(bodyHeight: height, onNatural: natural(for: .base))
        case .files:
            FilesSection(bodyHeight: height, sash: sash(above: .files, heights: heights))
        case .search:
            SearchSection(bodyHeight: height, sash: sash(above: .search, heights: heights))
        case .history:
            HistorySection(bodyHeight: height, sash: sash(above: .history, heights: heights))
        }
    }

    private func natural(for section: InspectorSection) -> (Double) -> Void {
        { height in
            // Rounded, and only on a real change: the report itself relays the column out.
            let rounded = height.rounded()
            if abs((naturals[section] ?? -1) - rounded) >= 1 { naturals[section] = rounded }
        }
    }

    /// The sash on top of `section`'s header when another open list sits above it: dragging moves height between the
    /// two and leaves every other list as it is.
    private func sash(above section: InspectorSection, heights: [InspectorSection: Double]) -> SectionSash? {
        guard heights[section] != nil else { return nil }
        let order = InspectorSection.allCases
        guard let index = order.firstIndex(of: section),
              let upper = order[..<index].last(where: { $0.fills && heights[$0] != nil }) else { return nil }
        let inspector = model.inspector
        let lists = heights.filter { $0.key.fills }
        return SectionSash(
            began: { inspector.dragStart = lists },
            moved: { delta in
                guard let start = inspector.dragStart else { return }
                inspector.weights = Layout.resize(heights: start, upper: upper, lower: section, by: delta)
            },
            ended: {
                inspector.dragStart = nil
                model.persistUIState()
            }
        )
    }

    // MARK: Viewer

    /// The viewer asked for, if it still has something to show: a diff needs the selected file of the selected task in
    /// a mode that has files, a file needs the base viewer to hold one.
    private var resolvedViewer: InspectorViewer? {
        model.inspector.viewer.flatMap(isShowable) == true ? model.inspector.viewer : nil
    }

    private func isShowable(_ viewer: InspectorViewer) -> Bool {
        switch viewer {
        case .diff:
            guard let task = model.currentTask, model.delta.taskID == task.id, model.delta.mode != .baseVsOrigin,
                  let ref = model.delta.selectedFile else { return false }
            return model.delta.file(ref) != nil && model.delta.taskRepo(ref.repo) != nil
        case .file:
            return model.base.content != nil
        }
    }

    private func viewerPane(_ viewer: InspectorViewer, total: Double, draggable: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
            switch viewer {
            case .diff:
                if let task = model.currentTask, let ref = model.delta.selectedFile, let file = model.delta.file(ref),
                   let repo = model.delta.taskRepo(ref.repo) {
                    DiffView(task: task, repo: repo, ref: ref, file: file,
                             leading: AnyView(backButton), trailing: AnyView(viewerControls))
                        .modifier(DeltaKeyboard(focused: $viewerFocused))
                }
            case .file:
                BaseFileViewer(leading: AnyView(backButton), trailing: AnyView(viewerControls))
            }
        }
        .overlay(alignment: .top) {
            if draggable { SashHandle(sash: viewerSash(total: total)) }
        }
        .frame(maxWidth: .infinity)
        .background(Surface.ground)
    }

    /// Back to what the viewer showed before, when that still has something to show.
    @ViewBuilder
    private var backButton: some View {
        if let previous = model.inspector.previousViewer, isShowable(previous) {
            Button {
                model.inspector.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.secondary)
            .help(previous == .diff ? "Back to the diff" : "Back to the base file")
            .accessibilityLabel("Back")
        }
    }

    /// Maximize and close, at the end of the viewer's header.
    private var viewerControls: some View {
        let maximized = model.inspector.viewerMaximized
        return HStack(spacing: 2) {
            Button {
                model.inspector.viewerMaximized.toggle()
            } label: {
                Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(maximized ? "Show the sections again" : "Fill the inspector with the viewer")
            .accessibilityLabel(maximized ? "Restore the sections" : "Maximize the viewer")
            Button {
                model.inspector.closeViewer()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close the viewer")
            .accessibilityLabel("Close the viewer")
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
    }

    private func viewerSash(total: Double) -> SectionSash {
        let inspector = model.inspector
        return SectionSash(
            began: { inspector.viewerDragStart = inspector.viewerShare },
            moved: { delta in
                guard let start = inspector.viewerDragStart, total > 0 else { return }
                inspector.viewerShare = Layout.clampViewerShare(start - delta / total)
            },
            ended: {
                inspector.viewerDragStart = nil
                model.persistUIState()
            }
        )
    }
}
