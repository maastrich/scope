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
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(repo.shortName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if repo.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else if let branch = repo.branchLabel {
                Text(branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }

            // The gutter `ThreadRow` reserves for its close button, so every row's trailing marker lands in the
            // same column whatever the section.
            Color.clear.frame(width: 16, height: 1)

            if repo.isDirty {
                Circle()
                    .fill(ThreadStateStyle.waiting)
                    .frame(width: 8, height: 8)
                    .help("Uncommitted changes")
            } else {
                Color.clear.frame(width: 8, height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel(repo.isDirty ? "\(repo.shortName), uncommitted changes" : repo.shortName)
        .help(repo.displayName == repo.shortName ? repo.url.path : "\(repo.displayName)\n\(repo.url.path)")
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open a Shell Here") {
            Task { _ = await model.newThread(in: scope.id, cwdKind: .repoBase(relativePath: repo.id)) }
        }
        Button("Open in Editor") {
            model.selection = .repo(scope.id, relativePath: repo.id)
            model.openInEditor(thread: nil)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(model.config.preferences.editor == nil)
        Button("See Base") {
            model.showBase(repo: repo, in: scope)
        }
        Button("See Graph") {
            model.selection = .repo(scope.id, relativePath: repo.id)
            model.inspectorTab = .graph
            model.inspectorShown = true
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
