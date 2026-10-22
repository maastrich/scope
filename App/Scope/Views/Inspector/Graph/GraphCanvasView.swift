import SwiftUI
import ScopeGraph

/// The Graph view: the repos that use one another as a layered drawing (`GraphLayout`), dependents above what they
/// depend on; the repos no link touches in a band of their own below it. Hovering a repo lights its links and its
/// neighbours; a click shows its card beside the drawing. Pinch, ⌘+ / ⌘− / ⌘0 or the buttons zoom; scrolling or
/// dragging the background moves it. The filter dims what it leaves out rather than moving anything: a drawing that
/// reshuffles on every keystroke cannot be read.
struct GraphCanvasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ScopeState

    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var hovered: String?
    @State private var position = ScrollPosition()
    @State private var offset: CGPoint = .zero
    @State private var dragOrigin: CGPoint?
    @State private var viewport: CGSize = .zero
    @State private var fitted = false

    static let nodeSize = CGSize(width: 180, height: 52)
    static let gap = CGSize(width: 28, height: 64)
    static let margin: CGFloat = 32
    static let zoomRange: ClosedRange<CGFloat> = 0.3...2

    private var layout: GraphLayout { model.graph.layout }

    private var canvasSize: CGSize {
        CGSize(width: CGFloat(layout.columns) * (Self.nodeSize.width + Self.gap.width) - Self.gap.width + Self.margin * 2,
               height: CGFloat(layout.rows) * (Self.nodeSize.height + Self.gap.height) - Self.gap.height + Self.margin * 2)
    }

    private func frame(_ key: String) -> CGRect? {
        guard let slot = layout.slots[key] else { return nil }
        return CGRect(x: Self.margin + CGFloat(slot.column) * (Self.nodeSize.width + Self.gap.width),
                      y: Self.margin + CGFloat(slot.row) * (Self.nodeSize.height + Self.gap.height),
                      width: Self.nodeSize.width, height: Self.nodeSize.height)
    }

    /// The repo whose links are lit: the hovered one, else the selected one.
    private var focus: String? { hovered ?? model.graph.selectedKey }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if layout.slots.isEmpty {
                    ContentUnavailableView {
                        Label("No relations yet", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("None of these repos says it uses another. Analyze with AI reads how they depend on one another.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    drawing
                }
                if !layout.isolated.isEmpty { isolatedBand }
            }
            if let key = model.graph.selectedKey, let entry = model.graph.entry(key) {
                Divider()
                ScrollView {
                    RepoCardView(scope: scope, entry: entry, isPanel: true).padding(10)
                }
                .frame(width: 300)
                .background(Surface.ground)
            }
        }
    }

    // MARK: Drawing

    private var drawing: some View {
        VStack(spacing: 0) {
            // Above the drawing, not over it: at a small zoom the first row would slide under them.
            HStack(spacing: 8) {
                legend
                Spacer(minLength: 8)
                zoomControls
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 10))
            scroller
        }
        .background(dotGrid)
    }

    private var scroller: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                // A drawing smaller than the view sits in its middle, not in its corner.
                .frame(minWidth: viewport.width, minHeight: viewport.height, alignment: .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, new in offset = new }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewport = size
            if !fitted, size.width > 0 { fitted = true; fit(animated: false) }
        }
        .gesture(MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                pinchBase = base
                zoom = (base * value.magnification).clamped(to: Self.zoomRange)
            }
            .onEnded { _ in pinchBase = nil })
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // The background takes the drag that moves the drawing, and a click on it clears the selection.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: canvasSize.width, height: canvasSize.height)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let origin = dragOrigin ?? offset
                        dragOrigin = origin
                        position.scrollTo(point: CGPoint(x: max(0, origin.x - value.translation.width),
                                                         y: max(0, origin.y - value.translation.height)))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .onTapGesture { model.graph.selectedKey = nil }
            edgesLayer
            ForEach(layout.slots.keys.sorted(), id: \.self) { key in
                if let entry = model.graph.entry(key), let rect = frame(key) {
                    node(entry)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var edgesLayer: some View {
        let focus = focus
        let edges = model.graph.edges
        let frames = Dictionary(uniqueKeysWithValues: layout.slots.keys.compactMap { key in frame(key).map { (key, $0) } })
        let quiet = Ink.tertiary
        return Canvas { context, _ in
            for edge in edges {
                guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
                let lit = focus != nil && (edge.from == focus || edge.to == focus)
                let downward = from.midY < to.midY
                let start = CGPoint(x: from.midX, y: downward ? from.maxY : from.minY)
                let end = CGPoint(x: to.midX, y: downward ? to.minY - 2 : to.maxY + 2)
                let bend = (end.y - start.y) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend))
                let color: Color = lit ? .accentColor : quiet
                let opacity: Double = lit ? 1 : (focus == nil ? 0.55 : 0.15)
                context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lit ? 1.8 : 1.1)
                // Arrowhead at the dependency.
                let dir: CGFloat = downward ? -1 : 1
                var head = Path()
                head.move(to: CGPoint(x: end.x - 4, y: end.y + 6 * dir))
                head.addLine(to: end)
                head.addLine(to: CGPoint(x: end.x + 4, y: end.y + 6 * dir))
                context.stroke(head, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: lit ? 1.8 : 1.1, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func node(_ entry: GraphCardEntry) -> some View {
        let focus = focus
        let neighbours = focus.map { GraphEdge.neighbours(of: $0, in: model.graph.edges) } ?? []
        let isFocus = entry.key == focus
        let isNeighbour = neighbours.contains(entry.key)
        let isSelected = entry.key == model.graph.selectedKey
        let passes = model.graph.matches(entry)
        let dimmed = !passes || (focus != nil && !isFocus && !isNeighbour)
        let relations = model.graph.relations(of: entry.key)
        return Button {
            model.graph.selectedKey = isSelected ? nil : entry.key
        } label: {
            // The name is never cut: it takes a second line, and the stack line gives way when it does.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    nodeName(entry)
                    Text(entry.tags.prefix(2).map(\.label).joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                nodeName(entry)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Surface.panel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFocus || isSelected ? Color.accentColor : (isNeighbour ? Color.accentColor.opacity(0.6) : Surface.stroke),
                              lineWidth: isFocus || isSelected ? 2 : 1))
            .shadow(color: .black.opacity(isFocus ? 0.12 : 0.04), radius: isFocus ? 6 : 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? (passes ? 0.35 : 0.2) : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dimmed)
        .onHover { inside in
            if inside { hovered = entry.key } else if hovered == entry.key { hovered = nil }
        }
        .help(entry.description?.text ?? entry.card.name)
        .contextMenu { RepoActions(model: model, scope: scope, entry: entry).menuItems(including: false) }
        .accessibilityLabel(entry.card.name)
        .accessibilityValue(relationsDescription(relations))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func nodeName(_ entry: GraphCardEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(DomainStyle.color(entry.domain)).frame(width: 7, height: 7)
            Text(entry.card.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relationsDescription(_ relations: (out: [String], in: [String])) -> String {
        var parts: [String] = []
        if !relations.out.isEmpty { parts.append("uses \(relations.out.joined(separator: ", "))") }
        if !relations.in.isEmpty { parts.append("used by \(relations.in.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    // MARK: Chrome

    private var dotGrid: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(Surface.stroke))
                    x += step
                }
                y += step
            }
        }
        .background(Surface.ground)
        .allowsHitTesting(false)
    }

    private var legend: some View {
        let domains = Set(layout.slots.keys.compactMap { model.graph.entry($0)?.domain }).sorted()
        return HStack(spacing: 10) {
            ForEach(domains, id: \.self) { domain in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(DomainStyle.color(domain)).frame(width: 7, height: 7)
                    Text(domain.title)
                }
            }
            Text("arrow → depends on").foregroundStyle(Ink.tertiary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Surface.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
    }

    private var zoomControls: some View {
        HStack(spacing: 1) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom Out (⌘−)")
                .accessibilityLabel("Zoom out")
            Text("\(Int((zoom * 100).rounded())) %")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom In (⌘+)")
                .accessibilityLabel("Zoom in")
            Button { fit(animated: true) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit the Drawing (⌘0)")
                .accessibilityLabel("Fit the drawing")
        }
        .buttonStyle(IconButtonStyle(padding: 4))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Ink.secondary)
        .padding(2)
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Surface.stroke))
    }

    private func setZoom(_ value: CGFloat) {
        let next = value.clamped(to: Self.zoomRange)
        if reduceMotion { zoom = next } else { withAnimation(.easeOut(duration: 0.15)) { zoom = next } }
    }

    /// The whole drawing in view, never larger than life and never so small a name cannot be read.
    private func fit(animated: Bool) {
        guard viewport.width > 0, canvasSize.width > 0 else { return }
        let scale = min(viewport.width / canvasSize.width, viewport.height / canvasSize.height, 1)
        let next = max(scale, 0.55).clamped(to: Self.zoomRange)
        if animated, !reduceMotion { withAnimation(.easeOut(duration: 0.15)) { zoom = next } } else { zoom = next }
        position.scrollTo(point: .zero)
    }

    // MARK: Isolated

    private var isolatedBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NO RELATIONS · \(layout.isolated.count)")
                .font(.scopeMicro)
                .tracking(0.6)
                .foregroundStyle(Ink.tertiary)
            ScrollView {
                FlowLayout(spacing: 5) {
                    ForEach(layout.isolated, id: \.self) { key in
                        if let entry = model.graph.entry(key) { isolatedChip(entry) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: layout.slots.isEmpty ? .infinity : 96)
            .fixedSize(horizontal: false, vertical: !layout.slots.isEmpty)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, maxHeight: layout.slots.isEmpty ? .infinity : nil, alignment: .topLeading)
        .background(Surface.panel)
        .overlay(alignment: .top) { Rectangle().fill(Surface.stroke).frame(height: 1) }
    }

    private func isolatedChip(_ entry: GraphCardEntry) -> some View {
        let isSelected = model.graph.selectedKey == entry.key
        return Button {
            model.graph.selectedKey = isSelected ? nil : entry.key
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(DomainStyle.color(entry.domain)).frame(width: 7, height: 7)
                Text(entry.card.name)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(isSelected ? Color.accentColor : Ink.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isSelected ? Fill.selectedTint : Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(model.graph.matches(entry) ? 1 : 0.3)
        .help(entry.description?.text ?? entry.card.name)
        .contextMenu { RepoActions(model: model, scope: scope, entry: entry).menuItems(including: false) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
