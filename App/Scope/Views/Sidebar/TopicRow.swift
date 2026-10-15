import SwiftUI
import ScopeCore
import ScopeTasks

/// The group row the tasks of one topic hang under, at the depth of a task, in the tree arrangement.
///
/// Built like **Loose threads**: not selectable — a topic has nothing of its own to show — it expands and collapses
/// and carries the most urgent state of its tasks' threads, so a collapsed group never hides an agent that wants
/// you. Its menu acts on the topic as a whole: rename it, take the tasks out of it, archive them together.
struct TopicRow: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let topic: String
    let tasks: [TaskState]

    var body: some View {
        let expanded = !scope.collapsedTopics.contains(TaskTopic.key(topic))
        HStack(spacing: SidebarMetrics.spacing) {
            SidebarDisclosure(
                isExpanded: expanded,
                accessibilityLabel: expanded ? "Collapse \(topic)" : "Expand \(topic)"
            ) {
                let key = TaskTopic.key(topic)
                if scope.collapsedTopics.contains(key) {
                    scope.collapsedTopics.remove(key)
                } else {
                    scope.collapsedTopics.insert(key)
                }
            }

            Image(systemName: "tag")
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .frame(width: SidebarMetrics.glyphSlot)

            Text(topic)
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text("\(tasks.count)")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)

            SidebarStateDot(state: ThreadState.mostUrgent(threads.map(\.displayState)),
                            pulses: threads.contains(where: \.isWorking))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: false))
        .contentShape(Rectangle())
        .help("Topic “\(topic)”: \(tasks.count) \(tasks.count == 1 ? "task" : "tasks")")
        .accessibilityLabel("Topic \(topic), \(tasks.count) tasks")
        .sidebarRow(selected: false)
        .contextMenu {
            Button("Rename Topic…") {
                guard let name = model.promptTopicName(title: "Rename Topic", current: topic, action: "Rename") else { return }
                Task { await model.renameTopic(topic, to: name, in: scope.id) }
            }
            Button("Ungroup Tasks") {
                Task { await model.setTopic(nil, for: tasks.map(\.id)) }
            }
            Divider()
            Button(tasks.count == 1 ? "Archive Task" : "Archive All \(tasks.count) Tasks") {
                Task { await model.archiveTopic(topic, in: scope.id) }
            }
        }
    }

    private var threads: [ThreadSession] {
        tasks.flatMap { model.threads(in: $0.id) }
    }
}
