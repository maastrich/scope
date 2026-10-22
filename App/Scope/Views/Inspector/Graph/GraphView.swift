import SwiftUI
import ScopeGraph

/// The Graph sheet (spec §4.6): a header with the scope, the view switch (Cards, List, Graph — remembered per
/// scope) and Analyze; a filter bar whose text and chips narrow the three views alike; then the view.
struct GraphView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let scope = model.currentScope {
            content(scope)
                .task(id: scope.id) { await model.graph.load(scope: scope) }
        } else {
            ContentUnavailableView {
                Label("No scope", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Select a scope to see its repository cards.")
            }
        }
    }

    private func mode(_ scope: ScopeState) -> Binding<GraphMode> {
        Binding(get: { model.graphPlaces[scope.id]?.mode ?? .cards },
                set: { model.graphPlaces[scope.id, default: GraphPlace()].mode = $0 })
    }

    private func content(_ scope: ScopeState) -> some View {
        let graph = model.graph
        return VStack(spacing: 0) {
            header(scope)
            if let progress = graph.progress {
                VStack(alignment: .leading, spacing: 3) {
                    ScopeProgressBar(fraction: Double(progress.finished) / Double(max(1, progress.total)))
                    Text(progress.caption)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
            }
            if !graph.cards.isEmpty { GraphFilterBar() }
            Divider()
            if graph.cards.isEmpty {
                ContentUnavailableView {
                    Label(graph.isLoading ? "Loading…" : "Not analyzed yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(graph.isLoading ? "" : "Analyze reads each repo's README, manifests and git log. With AI, the default driver refines the cards.")
                }
            } else if graph.filteredCards.isEmpty {
                ContentUnavailableView {
                    Label("No repo matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Nothing matches the filter.")
                } actions: {
                    Button("Clear Filter") { model.graph.filter = GraphFilter() }.buttonStyle(.scopeSecondary)
                }
            } else {
                switch mode(scope).wrappedValue {
                case .cards: GraphCardsView(scope: scope)
                case .list: GraphListView(scope: scope)
                case .graph: GraphCanvasView(scope: scope)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Surface.ground)
    }

    private func header(_ scope: ScopeState) -> some View {
        let graph = model.graph
        let repos = scope.repos.count
        let remotes = scope.repos.filter { $0.facts?.remote != nil }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(scope.name).font(.system(size: 12, weight: .semibold))
                    Text("· \(repos) \(repos == 1 ? "repo" : "repos") · \(remotes) \(remotes == 1 ? "remote" : "remotes")")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                }
                .lineLimit(1)
                Text(generatedCaption)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !graph.cards.isEmpty {
                TabStrip(selection: mode(scope), items: GraphMode.allCases.map { ($0, $0.title) })
                    .accessibilityLabel("View")
            }
            // Two controls where there was one split button: a plain `Menu` hides its `primaryAction` behind a
            // long press, and a button that only sometimes opens a menu is not something a label can say.
            HStack(spacing: 2) {
                Button {
                    Task { await model.analyzeGraph(scope: scope, withAI: false) }
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .buttonStyle(.scopeSecondary)
                .help(model.level1Unavailability.map { "Quick analysis (README, manifests, git log). AI: \($0)" }
                      ?? "Quick analysis (README, manifests, git log); the menu runs the default driver too")
                .accessibilityIdentifier("graph-analyze")
                ScopeIconMenu(systemImage: "chevron.down", title: "More ways to analyze") {
                    Button {
                        Task { await model.analyzeGraph(scope: scope, withAI: true) }
                    } label: {
                        Label("Analyze with AI (\(model.defaultDriverProfile?.name ?? "driver"))", systemImage: "sparkles")
                    }
                    .disabled(model.level1Unavailability != nil)
                    .help(model.level1Unavailability ?? "Level 1: the default driver in headless mode refines every card")
                    Button("Re-analyze Everything") {
                        Task { await model.analyzeGraph(scope: scope, withAI: false, force: true) }
                    }
                    Button("Re-analyze Everything with AI") {
                        Task { await model.analyzeGraph(scope: scope, withAI: true, force: true) }
                    }
                    .disabled(model.level1Unavailability != nil)
                    .help("Runs the driver again on every repository, the ones it already described included")
                }
            }
            .disabled(graph.isGenerating || scope.repos.isEmpty)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
    }

    private var generatedCaption: String {
        guard let date = model.graph.graph?.generatedAt else { return "Not analyzed yet" }
        return "Analyzed \(date.formatted(.relative(presentation: .named)))"
    }
}

/// The text field, then the domain chips and the most used tags: one line, never wrapped. Tags past the first few
/// are in *More*.
struct GraphFilterBar: View {
    @Environment(AppModel.self) private var model
    private static let shownTags = 5

    var body: some View {
        @Bindable var graph = model.graph
        let domains = GraphFacets.domains(graph.cards.map(\.domain))
        let tags = GraphFacets.tags(graph.cards.map(\.tags))
        // A tag picked from *More* stays on the bar while it is picked.
        let picked = tags.filter { graph.filter.tags.contains($0.key) }
        let shown = Array(tags.prefix(Self.shownTags)) + picked.filter { tag in !tags.prefix(Self.shownTags).contains(tag) }
        let rest = tags.filter { !shown.contains($0) }
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(Ink.secondary)
                TextField("Filter by name, description or tag", text: $graph.filter.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !graph.filter.text.isEmpty {
                    Button {
                        graph.filter.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the text")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 250, height: 24)
            .background(Surface.field, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Surface.stroke))
            .accessibilityIdentifier("graph-filter")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if domains.count > 1 {
                        label("Domain")
                        ForEach(domains, id: \.domain) { item in
                            FilterChip(title: item.domain.title, count: item.count, isOn: graph.filter.domains.contains(item.domain)) {
                                graph.filter.toggle(domain: item.domain)
                            }
                        }
                    }
                    if !shown.isEmpty {
                        label("Stack")
                        ForEach(shown, id: \.key) { tag in
                            FilterChip(title: tag.label, count: tag.count, isOn: graph.filter.tags.contains(tag.key)) {
                                graph.filter.toggle(tag: tag.key)
                            }
                        }
                    }
                    if !rest.isEmpty {
                        ScopeMenu {
                            ForEach(rest, id: \.key) { tag in
                                Button("\(tag.label) · \(tag.count)") { graph.filter.toggle(tag: tag.key) }
                            }
                        } label: { hovering in
                            HStack(spacing: 3) {
                                Text("More")
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            }
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(hovering ? Fill.hover : Surface.panel, in: Capsule())
                            .overlay(Capsule().strokeBorder(Surface.stroke))
                        }
                        .fixedSize()
                    }
                    if !graph.filter.domains.isEmpty || !graph.filter.tags.isEmpty {
                        Button("Clear") {
                            graph.filter.domains = []
                            graph.filter.tags = []
                        }
                        .buttonStyle(.scopeLink)
                        .font(.scopeCaption)
                    }
                }
                .padding(.trailing, 16)
            }
            // Chips that run past the edge fade out instead of being cut through a word.
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
            })
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.scopeMicro)
            .tracking(0.6)
            .foregroundStyle(Ink.tertiary)
            .padding(.leading, 4)
    }
}

/// A filter chip of the bar: a name and how many repos it would keep; picked, it takes the selection tint.
struct FilterChip: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(isOn ? Color.accentColor.opacity(0.75) : Ink.tertiary)
            }
            .font(.scopeCaption)
            .foregroundStyle(isOn ? Color.accentColor : Ink.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(isOn ? Fill.selectedTint : (hovering ? Fill.hover : Surface.panel), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Surface.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "repo" : "repos")")
    }
}

/// The Cards view: one foldable group per domain, uniform cards in a grid.
///
/// A grid of compact cards rather than masonry columns: every card has the same parts at the same heights (two
/// lines of description reserved, one row of tags, details folded), so rows line up without gaps, the reading and
/// Tab order stay left to right, and the grid stays lazy. Masonry would fill the gaps that cards of very different
/// heights left, but those heights were the bug; it would also scatter the order across columns.
struct GraphCardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ScopeState

    var body: some View {
        let collapsed = model.graphPlaces[scope.id]?.collapsed ?? []
        let groups = model.graph.groups
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    ForEach(groups, id: \.group.id) { item in
                        let group = item.group
                        let isCollapsed = collapsed.contains(group.id) && groups.count > 1
                        if groups.count > 1 {
                            groupHeader(group, count: item.entries.count, collapsed: isCollapsed)
                        }
                        if !isCollapsed {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 10, alignment: .top)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(item.entries) { entry in
                                    RepoCardView(scope: scope, entry: entry).id(entry.key)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 14, bottom: 14, trailing: 14))
            }
            .onChange(of: model.graph.highlightedKey, initial: true) { _, key in
                guard let key, let group = model.graph.group(of: key) else { return }
                model.graph.collapse(group.id, false, in: scope.id, places: model)
                DispatchQueue.main.async {
                    if reduceMotion { proxy.scrollTo(key, anchor: .top) } else { withAnimation { proxy.scrollTo(key, anchor: .top) } }
                }
            }
        }
    }

    private func groupHeader(_ group: DomainGroup, count: Int, collapsed: Bool) -> some View {
        Button {
            model.graph.collapse(group.id, !collapsed, in: scope.id, places: model)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title.uppercased()).tracking(0.6)
                Text("\(count)").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .font(.scopeMicro)
            .foregroundStyle(Ink.tertiary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(count) \(count == 1 ? "repo" : "repos")")
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
    }
}

/// The List view: one dense, sortable row per repo. A double-click or ↩ opens its card.
struct GraphListView: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    @State private var sortOrder = [KeyPathComparator(\Row.name)]

    struct Row: Identifiable {
        let entry: GraphCardEntry
        var id: String { entry.key }
        var name: String { entry.card.name.lowercased() }
        var domain: String { entry.domain.title }
        var stack: String { entry.tags.prefix(4).map(\.label).joined(separator: " · ") }
        var activity: Date { entry.card.lastActivity ?? .distantPast }
        var branch: String { entry.card.defaultBranch ?? "" }
        let uses: Int
        let usedBy: Int
        var relations: Int { uses + usedBy }
    }

    var body: some View {
        @Bindable var graph = model.graph
        let rows = graph.filteredCards.map { entry in
            let relations = graph.relations(of: entry.key)
            return Row(entry: entry, uses: relations.out.count, usedBy: relations.in.count)
        }.sorted(using: sortOrder)
        Table(rows, selection: $graph.selectedKey, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.entry.card.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                    if let subtitle = row.entry.subtitle {
                        Text(subtitle).font(.scopeCaption).foregroundStyle(Ink.tertiary)
                    }
                }
                .lineLimit(1)
                .help(row.entry.description?.text ?? "")
            }
            .width(min: 180, ideal: 300)
            TableColumn("Domain", value: \.domain) { row in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(DomainStyle.color(row.entry.domain)).frame(width: 7, height: 7)
                    Text(row.domain)
                }
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Stack", value: \.stack) { row in
                Text(row.stack).font(.scopeCaption).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Last activity", value: \.activity) { row in
                Text(row.entry.card.lastActivity.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .font(.scopeCaption).foregroundStyle(Ink.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Branch", value: \.branch) { row in
                Text(row.branch).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Relations", value: \.relations) { row in
                Text(relationsText(row)).font(.scopeCaption).foregroundStyle(row.relations == 0 ? Ink.tertiary : Ink.secondary)
                    .help(relationsHelp(row))
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Surface.ground)
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let entry = graph.entry(key) {
                RepoActions(model: model, scope: scope, entry: entry).menuItems()
                Button("Show Card") { RepoActions(model: model, scope: scope, entry: entry).showCard() }
            }
        } primaryAction: { keys in
            if let key = keys.first, let entry = graph.entry(key) { RepoActions(model: model, scope: scope, entry: entry).showCard() }
        }
        .accessibilityIdentifier("graph-list")
    }

    private func relationsText(_ row: Row) -> String {
        switch (row.uses, row.usedBy) {
        case (0, 0): "—"
        case (let out, 0): "→ \(out)"
        case (0, let used): "← \(used)"
        case (let out, let used): "→ \(out) · ← \(used)"
        }
    }

    private func relationsHelp(_ row: Row) -> String {
        let relations = model.graph.relations(of: row.id)
        var parts: [String] = []
        if !relations.out.isEmpty { parts.append("Uses \(relations.out.joined(separator: ", "))") }
        if !relations.in.isEmpty { parts.append("Used by \(relations.in.joined(separator: ", "))") }
        return parts.joined(separator: "\n")
    }
}
