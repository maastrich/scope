import SwiftUI

/// Right-hand inspector, about the selection alone: one segmented control in a 30 pt header — Delta, Pull
/// Request, Base — then the summary band naming the subject, then the panel pinned to the top. ⌘D / ⇧⌘B
/// switch tabs.
///
/// Delta and Pull Request follow the selected task; Base follows the task's repositories, or the selected repo
/// when no task is selected, so a repo row or a loose thread still has a Base to show. The scope-wide views
/// that used to share this header — the graph, a repo's open pull requests — moved to sheets opened from the
/// sidebar: with them here the tabs followed two subjects at once and nothing said which applied.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // One 30 pt band, level with the window toolbar, so the header reads as a single line across the window.
            HStack(spacing: 8) {
                Picker("Panel", selection: $model.inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color("PanelBackground"))
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
        .background(Color(nsColor: .windowBackgroundColor))
        // A task-only tab left showing with no task would sit on an empty state forever; Base always has a subject.
        .onChange(of: model.currentTask == nil, initial: true) { _, noTask in
            if noTask, model.inspectorTab.needsTask { model.inspectorTab = .base }
        }
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
                .foregroundStyle(.secondary)
            Text(repo.shortName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("repository")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text("No task selected")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("PanelBackground"))
        .help(repo.url.path)
    }
}
