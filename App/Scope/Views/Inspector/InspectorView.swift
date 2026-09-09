import SwiftUI

/// Right-hand inspector: two segmented controls in a 30 pt header — Delta / PRs, which follow the selected task,
/// and Base / Graph, which follow the scope and its repositories — then the task summary band on the first pair,
/// then the panel pinned to the top. ⌘D / ⌘⇧B switch tabs.
///
/// The header used to carry `contextDescription` as its caption, which is derived from `newThreadTarget`: the
/// panel labelled itself with ⌘T's next destination rather than with what it was showing. `TaskSummaryBand` says
/// it properly now, so the caption is gone.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // One 30 pt band, level with the window toolbar, so the header reads as a single line across the window.
            HStack(spacing: 8) {
                // Two groups, because the tabs follow two different subjects: Delta and PRs are about the selected
                // task, Base and Graph about the scope and its repositories. Without the split, selecting a task
                // while sitting on Graph silently keeps showing something else.
                Picker("Task", selection: $model.inspectorTab) {
                    ForEach(InspectorTab.allCases.filter(\.followsTask), id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(model.currentTask == nil)
                .help(model.currentTask == nil ? "Select a task or one of its threads" : "The selected task")

                Picker("Scope", selection: $model.inspectorTab) {
                    ForEach(InspectorTab.allCases.filter { !$0.followsTask }, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("The scope and its repositories")

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color("PanelBackground"))
            Divider()
            // Only under the tabs that follow a task: Base and Graph are about the scope and its repos, and give
            // the height back to their own content.
            if model.inspectorTab.followsTask, let task = model.currentTask {
                TaskSummaryBand(task: task)
                Divider()
            }
            Group {
                switch model.inspectorTab {
                case .graph:
                    GraphView()
                case .delta:
                    DeltaView()
                case .base:
                    BaseView()
                case .pullRequests:
                    PullRequestsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
