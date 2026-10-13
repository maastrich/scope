import SwiftUI

/// Right-hand inspector, about the selection alone: one segmented control in a 30 pt header — Delta, Pull
/// Request, Base — then the summary band naming the subject, then the panel pinned to the top. ⌘D / ⇧⌘B
/// switch tabs.
///
/// Delta and Pull Request follow the selected task; Base follows `AppModel.baseSubject`, which always has a
/// repository to show, so a repo row or a loose thread still has a Base. Without a task the inspector shows
/// Base and keeps the task's own tab for the next task (`AppModel.inspectorTab`). The scope-wide views
/// that used to share this header — the graph, a repo's open pull requests — moved to sheets opened from the
/// sidebar: with them here the tabs followed two subjects at once and nothing said which applied.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // One 30 pt band, level with the window toolbar, so the header reads as a single line across the window.
            HStack(spacing: 8) {
                TabStrip(selection: $model.inspectorTab,
                         items: InspectorTab.allCases.map { ($0, $0.title) })
                    .accessibilityLabel("Panel")
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Surface.panel)
            Divider()
            if let task = model.currentTask {
                TaskSummaryBand(task: task)
                Divider()
            } else if let repo = model.baseRepo {
                RepoSummaryBand(repo: repo)
                Divider()
            }
            Group {
                switch model.inspectorTab {
                case .delta:
                    DeltaView()
                case .pullRequest:
                    TaskPullRequestView()
                case .base:
                    BaseView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.ground)
    }
}

/// The band under the tab row when no task is selected: the repo the Base panel shows, so the panel still says
/// *what* it is about. The task band's counterpart, one row tall.
private struct RepoSummaryBand: View {
    let repo: RepoState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
            Text(repo.shortName)
                .font(.scopeTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("repository")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
            Spacer(minLength: 4)
            Text("No task selected")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.panel)
        .help(repo.url.path)
    }
}
