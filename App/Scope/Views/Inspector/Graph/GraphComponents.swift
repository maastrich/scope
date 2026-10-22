import AppKit
import SwiftUI
import ScopeCore
import ScopeGraph

/// The colour of a domain: its square in the Graph view and the legend. Semantic assets only, so each has its light
/// and dark value and reads at 3:1 on the ground; none is the accent, which stays for selection.
enum DomainStyle {
    static func color(_ domain: RepoDomain) -> Color {
        switch domain {
        case .frontend: ThreadStateStyle.done
        case .backend: ThreadStateStyle.running
        case .library: Origin.agent
        case .infra: ThreadStateStyle.waiting
        case .data: PullRequestStyle.failing
        case .mobile: PullRequestStyle.pending
        case .docs: Ink.secondary
        case .tooling: ThreadStateStyle.idle
        case .other: Ink.tertiary
        }
    }
}

/// A tag of a card: a quiet chip that is also a filter. Picked, it takes the selection tint.
struct TagChip: View {
    @Environment(AppModel.self) private var model
    let tag: DisplayTag

    static let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let horizontalPadding: CGFloat = 6

    /// What the chip will measure, without laying it out: `TagRow` decides how many fit from these.
    static func width(_ label: String) -> Double {
        // 2 pt of slack: SwiftUI's text measures a hair wider than AppKit's, and a chip that does not quite fit
        // truncates rather than moving to "+N".
        Double(ceil((label as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding * 2 + 2)
    }

    var body: some View {
        let active = model.graph.filter.tags.contains(tag.key)
        Button {
            model.graph.filter.toggle(tag: tag.key)
        } label: {
            Text(tag.label)
                .font(Font(Self.font))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Ink.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: 18)
                .background(active ? Fill.selectedTint : Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "Stop filtering by \(tag.label)" : "Show only repos tagged \(tag.label)")
        .accessibilityLabel(tag.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One row of tags, never wrapped and never cut mid-word: as many as fit (six at most), then `+N`, which opens the
/// rest. Before, the tags sat in an `HStack` that squeezed each into a column and broke `#design-system` into four
/// lines.
struct TagRow: View {
    let tags: [DisplayTag]
    @State private var width: CGFloat = 0
    @State private var showsRest = false

    private static let spacing: CGFloat = 4

    var body: some View {
        let visible = TagOverflow.visibleCount(widths: tags.map { TagChip.width($0.label) }, available: Double(width),
                                               spacing: Double(Self.spacing), moreWidth: TagChip.width("+\(tags.count)"))
        let shown = width == 0 ? 0 : visible
        HStack(spacing: Self.spacing) {
            ForEach(tags.prefix(shown)) { TagChip(tag: $0) }
            if shown < tags.count, shown > 0 {
                Button {
                    showsRest.toggle()
                } label: {
                    Text("+\(tags.count - shown)")
                        .font(Font(TagChip.font))
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, TagChip.horizontalPadding)
                        .frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(Surface.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .buttonStyle(.plain)
                .help(tags.dropFirst(shown).map(\.label).joined(separator: ", "))
                .accessibilityLabel("\(tags.count - shown) more tags")
                .popover(isPresented: $showsRest, arrowEdge: .bottom) {
                    FlowLayout(spacing: Self.spacing) {
                        ForEach(tags.dropFirst(shown)) { TagChip(tag: $0) }
                    }
                    .frame(width: 240, alignment: .leading)
                    .padding(10)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// What can be done with a repo of the graph — the card's hover bar, its context menu, its VoiceOver actions and the
/// List view's rows all list these, so they never disagree. None is destructive.
@MainActor
struct RepoActions {
    let model: AppModel
    let scope: ScopeState
    let entry: GraphCardEntry

    var repo: RepoState? { scope.repos.first { GraphModel.key(for: $0) == entry.key } }

    func openInEditor() { if let repo { model.openInEditorOrCopy(path: repo.url.path) } }
    func showBase() { if let repo { model.showBase(repo: repo, in: scope) } }
    func reveal() { if let repo { Reveal.inFinder(repo.url) } }
    func copyPath() {
        guard let repo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repo.url.path, forType: .string)
    }
    func edit() {
        model.graphPlaces[scope.id, default: GraphPlace()].mode = .cards
        model.graph.expanded.insert(entry.key)
        model.graph.highlightedKey = entry.key
        model.graph.editingKey = entry.key
    }
    func showInGraph() {
        model.graphPlaces[scope.id, default: GraphPlace()].mode = .graph
        model.graph.selectedKey = entry.key
    }
    func showCard() {
        model.graphPlaces[scope.id, default: GraphPlace()].mode = .cards
        if let group = model.graph.group(of: entry.key) { model.graph.collapse(group.id, false, in: scope.id, places: model) }
        model.graph.highlightedKey = entry.key
    }

    /// The context menu, as a menu's items.
    @ViewBuilder
    func menuItems(including extra: Bool = true) -> some View {
        if repo != nil {
            Button("Open in Editor") { openInEditor() }
            Button("Show in Base") { showBase() }
            Button("Reveal in Finder") { reveal() }
            Button("Copy Path") { copyPath() }
            Divider()
        }
        if extra {
            Button("Show in Graph") { showInGraph() }
        }
        Button("Edit Card…") { edit() }
    }
}

extension GraphModel {
    /// Folds or unfolds a domain group of the Cards view, remembered per scope.
    func collapse(_ group: String, _ collapsed: Bool, in scope: ScopeID, places model: AppModel) {
        var place = model.graphPlaces[scope] ?? GraphPlace()
        if collapsed { place.collapsed.insert(group) } else { place.collapsed.remove(group) }
        model.graphPlaces[scope] = place
    }
}

/// Wraps its children onto as many rows as needed (the rest of a card's tags, the isolated repos, related links).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in layout(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
