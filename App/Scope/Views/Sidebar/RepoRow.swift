import SwiftUI
import ScopeCore

/// Sidebar row for a discovered repository: the repo name (never `owner/`), one trailing chip (refresh spinner,
/// else the branch) and the dirty dot; the full `owner/repo` and path live in the hover tooltip.
/// Lives in the collapsible Repositories section of the sidebar.
struct RepoRow: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let repo: RepoState

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Text(repo.shortName)
                .font(.scopeBody)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if repo.isRefreshing {
                ScopeSpinner(size: 10)
            } else if let branch = repo.branchLabel {
                Chip(text: branch, mono: true)
            }

            // The dot in the column every other row ends with, so the chip does not read as the dot's label.
            Group {
                if repo.isDirty {
                    Circle()
                        .fill(ThreadStateStyle.waiting)
                        .frame(width: SidebarMetrics.stateDot, height: SidebarMetrics.stateDot)
                        .help("Uncommitted changes")
                } else {
                    Color.clear
                }
            }
            .frame(width: SidebarMetrics.stateDotColumn, height: SidebarMetrics.stateDotColumn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: false))
        .contentShape(Rectangle())
        .accessibilityLabel(repo.isDirty ? "\(repo.shortName), uncommitted changes" : repo.shortName)
        .help(repo.displayName == repo.shortName ? repo.url.path : "\(repo.displayName)\n\(repo.url.path)")
        .contextMenu { contextMenu }
        .sidebarRow(selected: model.selection == .repo(scope.id, relativePath: repo.id))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open a Shell Here") {
            Task { _ = await model.newThread(in: scope.id, cwdKind: .repoBase(relativePath: repo.id)) }
        }
        Button("Open in Editor") {
            model.openInEditor(path: repo.url.path)
        }
        .keyboardShortcut("e", modifiers: .command)
        Button("See Base") {
            model.showBase(repo: repo, in: scope)
        }
        Button("See Graph") {
            model.graph.highlightedKey = GraphModel.key(for: repo)
            model.presentGraph()
        }
        Divider()
        Button("Reveal in Finder") {
            Reveal.inFinder(repo.url)
        }
        Button("Copy Path") {
            Pasteboard.copyPath(repo.url)
        }
        Divider()
        Button("Refresh") {
            repo.refreshFacts()
        }
    }
}
