import SwiftUI

/// `from <parent>` at the start of a child task's second line, in the tree: a click selects the parent. An archived
/// parent has no row to go to, so it is named and not linked.
struct ParentTaskLink: View {
    @Environment(AppModel.self) private var model
    let parent: TaskState
    @State private var isHovered = false

    /// The parent's name gives way before the line it opens: this many characters at most, the full name in the help.
    private static let nameLimit = 22

    var body: some View {
        if parent.isArchived {
            label.help("Started from “\(parent.name)”, archived since")
        } else {
            Button {
                model.selectLinkedTask(parent)
            } label: {
                label.underline(isHovered)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Started from “\(parent.name)”. Click to select it.")
            .accessibilityLabel("Go to parent task \(parent.name)")
        }
    }

    private var shortName: String {
        parent.name.count > Self.nameLimit ? parent.name.prefix(Self.nameLimit - 1) + "…" : parent.name
    }

    private var label: some View {
        Text("from \(shortName)")
            .font(.scopeCaption)
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A task's way to the tasks it is linked to: the one it was started from, and those started from it.
struct DelegationMenuItems: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        if let parent = model.parentTask(of: task), !parent.isArchived {
            Button("Go to Parent Task “\(parent.name)”") { model.selectLinkedTask(parent) }
        }
        let children = model.childTasks(of: task)
        if !children.isEmpty {
            Menu("Tasks Started From Here") {
                ForEach(children) { child in
                    Button(child.name) { model.selectLinkedTask(child) }
                }
            }
        }
    }
}
