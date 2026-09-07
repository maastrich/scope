import SwiftUI
import ScopeGraph

/// The Graph inspector panel (spec §4.6, design §6): header with the Analyze split button and the
/// generation progress, then one card per repo of the current scope.
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

    private func content(_ scope: ScopeState) -> some View {
        let graph = model.graph
        return VStack(spacing: 0) {
            header(scope)
            if let progress = graph.progress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(progress.finished), total: Double(max(1, progress.total)))
                        .controlSize(.small)
                    Text(progress.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
            }
            if !graph.cards.isEmpty { filterField }
            Divider()
            if graph.cards.isEmpty {
                ContentUnavailableView {
                    Label(graph.isLoading ? "Loading…" : "Not analyzed yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(graph.isLoading ? "" : "Analyze reads each repo's README, manifests and git log. With AI, the default driver refines the cards.")
                }
            } else {
                cards(scope)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func header(_ scope: ScopeState) -> some View {
        let graph = model.graph
        let repos = scope.repos.count
        let remotes = scope.repos.filter { $0.facts?.remote != nil }.count
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(scope.name).font(.system(size: 12, weight: .semibold))
                    Text("· \(repos) \(repos == 1 ? "repo" : "repos") · \(remotes) \(remotes == 1 ? "remote" : "remotes")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(generatedCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
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
            } label: {
                Label("Analyze", systemImage: "sparkles")
            } primaryAction: {
                Task { await model.analyzeGraph(scope: scope, withAI: false) }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(graph.isGenerating || scope.repos.isEmpty)
            .help(model.level1Unavailability.map { "Quick analysis (README, manifests, git log). AI: \($0)" }
                  ?? "Quick analysis (README, manifests, git log); the menu runs the default driver too")
            .accessibilityIdentifier("graph-analyze")
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
    }

    /// Path / name / stack substring filter; only shown once there are cards to narrow.
    private var filterField: some View {
        @Bindable var graph = model.graph
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter by path or stack", text: $graph.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !graph.filter.isEmpty {
                Button {
                    graph.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
        .accessibilityIdentifier("graph-filter")
    }

    private var generatedCaption: String {
        guard let date = model.graph.graph?.generatedAt else { return "Not analyzed yet" }
        return "Generated \(date.formatted(.relative(presentation: .named)))"
    }

    private func cards(_ scope: ScopeState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.graph.filteredCards) { entry in
                        RepoCardView(scope: scope, entry: entry)
                            .id(entry.key)
                    }
                    if model.graph.filteredCards.isEmpty {
                        Text("No card matches “\(model.graph.filter)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 12, trailing: 14))
            }
            .onChange(of: model.graph.highlightedKey) { _, key in
                guard let key else { return }
                withAnimation { proxy.scrollTo(key, anchor: .top) }
            }
        }
    }
}
