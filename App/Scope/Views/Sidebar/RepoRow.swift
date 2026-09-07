import SwiftUI
import ScopeCore

/// Sidebar row for a discovered repository: `owner/repo` (or the folder name), branch chip, dirty dot.
/// In M0 repo rows stand in for the task rows of the final design (depth 1).
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

            Text(repo.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if repo.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            if let branch = repo.branchLabel {
                Text(branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            if repo.isDirty {
                Circle()
                    .fill(ThreadStateStyle.waiting)
                    .frame(width: 6, height: 6)
                    .help("Uncommitted changes")
            }
        }
        .padding(.leading, 16)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(repo.url.path)
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
