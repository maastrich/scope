import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// Right-hand inspector, about the selection alone: a 30 pt band naming the subject, level with the window toolbar,
/// with the pane strip at its right, then a column of cards — Environment, Changes, Pull requests, Artifacts,
/// Context, Connectors, Subagents, Background, Repository, Files, Search, History.
///
/// Cards, not tabs: every one is there (unless taken out through the Cards menu), so the column says at a glance
/// what exists, and a closed one costs a line while its header keeps the essential (`+108 −12`, the branch and its
/// lag, the checks). Several can be open; the lists among them share the height and the sash between two open lists
/// moves it. Which are open and which are shown is kept per scope (`ScopePlace`), separately with and without a task,
/// and comes back as it was left.
///
/// The sections hold lists only. A diff or a base file opens in `InspectorViewerColumn`, a column of its own beside
/// the inspector — VSCode's editor area to this sidebar — so reading one never moves a section header.
///
/// The loads every header needs run here rather than in the section bodies, so a closed section's summary is current.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    /// Height each block section's content asks for, reported by the section.
    @State private var naturals: [InspectorSection: Double] = [:]

    private typealias Layout = InspectorSectionLayout
    /// A card is its header, its body and the gap above it; the column ends on one more gap.
    private static let gap: Double = Layout.cardGap
    /// What notices the pull request a thread opened and binds it, and keeps its checks fresh.
    static let pullRequestRefreshInterval: Duration = .seconds(60)

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
                try? await Task.sleep(for: Self.pullRequestRefreshInterval)
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
        let visible = model.inspector.sections.visible
        let items = visible.map { section in
            Layout.Item(section: section,
                        isOpen: model.isSectionAvailable(section) && model.isSectionOpen(section),
                        natural: naturals[section] ?? 0)
        }
        let heights = Layout.bodyHeights(available: total - Double(items.count + 1) * Self.gap, items: items,
                                         weights: model.inspector.weights)
        let content = Double(items.count) * (Layout.headerHeight + Self.gap) + Self.gap + heights.values.reduce(0, +)
        ScrollView(.vertical) {
            VStack(spacing: Self.gap) {
                ForEach(visible, id: \.self) { section in
                    sectionView(section, heights: heights, order: visible)
                }
            }
            .padding(.horizontal, Self.gap)
            .padding(.vertical, Self.gap)
        }
        .scrollDisabled(content <= total + 0.5)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: total, alignment: .top)
    }

    @ViewBuilder
    private func sectionView(_ section: InspectorSection, heights: [InspectorSection: Double], order: [InspectorSection]) -> some View {
        let height = heights[section]
        switch section {
        case .environment:
            EnvironmentCard(bodyHeight: height, onNatural: natural(for: .environment))
        case .plan:
            PlanCard(bodyHeight: height, onNatural: natural(for: .plan))
        case .delta:
            DeltaSection(bodyHeight: height, sash: sash(above: .delta, heights: heights, order: order))
        case .pullRequest:
            PullRequestSection(bodyHeight: height, onNatural: natural(for: .pullRequest))
        case .artifacts:
            ArtifactsCard(bodyHeight: height, onNatural: natural(for: .artifacts))
        case .context:
            ContextCard(bodyHeight: height, onNatural: natural(for: .context))
        case .connectors:
            ConnectorsCard(bodyHeight: height, onNatural: natural(for: .connectors))
        case .background:
            BackgroundCard(bodyHeight: height, onNatural: natural(for: .background))
        case .subagents:
            SubagentsCard(bodyHeight: height, onNatural: natural(for: .subagents))
        case .base:
            BaseSection(bodyHeight: height, onNatural: natural(for: .base))
        case .files:
            FilesSection(bodyHeight: height, sash: sash(above: .files, heights: heights, order: order))
        case .search:
            SearchSection(bodyHeight: height, sash: sash(above: .search, heights: heights, order: order))
        case .history:
            HistorySection(bodyHeight: height, sash: sash(above: .history, heights: heights, order: order))
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
    private func sash(above section: InspectorSection, heights: [InspectorSection: Double], order: [InspectorSection]) -> SectionSash? {
        guard heights[section] != nil else { return nil }
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
            },
            reset: {
                inspector.weights = Layout.equalize(heights: lists, upper: upper, lower: section)
                model.persistUIState()
            }
        )
    }
}
