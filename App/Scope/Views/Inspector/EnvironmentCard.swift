import AppKit
import SwiftUI
import ScopeCore
import ScopeTasks

/// The Environment card: where the task runs. Closed, the branch and where it stands (commits ahead, base moved
/// on); open, the version strip, one line per worktree with its sandbox state and `+N −M`, the ports something of
/// the task listens on, and what the sandboxes weigh. Add Branch, Copy name, Open in Editor and Reveal come on hover.
struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .environment, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { TaskVersionSummary(task: task) }
        } actions: {
            if let task { actions(task) }
        } content: {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    if !task.record.trying.isEmpty {
                        TryBanner(task: task, sessions: task.record.trying, placement: "inspector.environment")
                            .padding(.bottom, 8)
                    }
                    TaskVersionStrip(task: task)
                    ForEach(task.activeSandboxes, id: \.sandboxKey) { repo in
                        TaskRepoRow(task: task, repo: repo)
                    }
                    TaskPortsRow(task: task)
                    TaskMachineRow(task: task)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func actions(_ task: TaskState) -> some View {
        if !task.isArchived {
            Button {
                model.addBranchFromUI(task)
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .help("Add Branch… — a second worktree of a repository of the task, on a branch of its own")
            .accessibilityLabel("Add a branch to \(task.name)")
            .usageID("inspector.environment.add-branch", label: "Add a branch to the task")
        }
        // The name is how the task is referred to in a prompt; ⌥ gives the slug `scope --task` takes.
        CopyButton(label: "Copy task name") {
            NSEvent.modifierFlags.contains(.option) ? task.record.slug : task.name
        }
        .help("Copy the task name — ⌥-click copies the slug “\(task.record.slug)”")
        Button {
            model.openTaskInEditor(task)
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .help("Open Task in Editor (⇧⌘E)")
        .accessibilityLabel("Open \(task.name) in Editor")
        Button {
            Reveal.inFinder(task.record.rootURL)
        } label: {
            Image(systemName: "folder")
        }
        .help("Reveal in Finder")
        .accessibilityLabel("Reveal \(task.name) in Finder")
    }
}

/// The ports line: the chips of the ports something listens on (`AppModel+Ports`), or *nothing listening*.
private struct TaskPortsRow: View {
    let task: TaskState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CardRowGlyph("network")
            Text("Ports")
                .font(.system(size: 12, weight: .semibold))
            if task.listeningPorts.isEmpty {
                Spacer(minLength: 0)
                Text("nothing listening")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            } else {
                TaskPortChips(task: task, compact: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .usageID("task-servers", label: "Task servers")
    }
}

/// The foot of the card: this machine and what the sandboxes weigh (`AppModel+DiskUsage`), once measured.
private struct TaskMachineRow: View {
    let task: TaskState

    var body: some View {
        if task.diskUsage != nil {
            HStack(spacing: 8) {
                CardRowGlyph("laptopcomputer")
                Text("This Mac")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Text("·")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                TaskDiskCaption(task: task)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .usageID("task-disk", label: "Task disk usage")
        }
    }
}
