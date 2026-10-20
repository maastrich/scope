import SwiftUI
import ScopeCore
import ScopeTasks

/// A mission's milestones under the brief: one row each with its state, its validation and the child task, and the
/// end of a failed validation's log on hover. Scope only shows what the record holds; the orchestrator moves it.
struct MissionChecklist: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let mission: Mission

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text("Mission")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(mission.caption)
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            if mission.milestones.isEmpty {
                Text("The agent names the milestones as it plans them (`scope task milestone add`).")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(mission.milestones.enumerated()), id: \.element.id) { index, milestone in
                MilestoneRow(task: task, number: index + 1, milestone: milestone)
            }
        }
        .padding(.vertical, 6)
        .usageID("mission", label: "Mission milestones")
    }
}

struct MilestoneRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let number: Int
    let milestone: Milestone
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 14)
                .accessibilityLabel(milestone.state.rawValue)
            Text("\(number).")
                .font(.scopeCaption.monospacedDigit())
                .foregroundStyle(Ink.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(milestone.title)
                    .font(.scopeBody)
                    .lineLimit(2)
                    .strikethrough(milestone.state == .validated, color: Ink.tertiary)
                    .foregroundStyle(milestone.state == .validated ? Ink.secondary : Ink.primary)
                HStack(spacing: 4) {
                    if let child = milestone.task.flatMap(model.task) {
                        Button(child.name) { model.switchToTask(child) }
                            .buttonStyle(.scopeLink)
                            .font(.scopeCaption)
                            .lineLimit(1)
                            .help("Show the task doing this milestone")
                            .usageID("milestone-child", label: "Show a milestone's task")
                        if milestone.validation != nil { Text("·").font(.scopeCaption).foregroundStyle(Ink.tertiary) }
                    }
                    if let validation = milestone.validation {
                        Text(validation)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("Run in the sandbox when the milestone is marked done")
                    }
                    if let exit = milestone.exit, milestone.state == .failed {
                        Text(exit)
                            .font(.scopeCaption)
                            .foregroundStyle(Color("WarningText"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(milestone.log ?? milestone.title)
    }

    private var symbol: String {
        switch milestone.state {
        case .open: "circle"
        case .done: milestone.validation == nil ? "checkmark.circle.fill" : "clock"
        case .validated: "checkmark.circle.fill"
        case .failed: "xmark.circle"
        }
    }

    private var color: Color {
        switch milestone.state {
        case .open: Ink.tertiary
        case .done: milestone.validation == nil ? ThreadStateStyle.done : ThreadStateStyle.waiting
        case .validated: ThreadStateStyle.done
        case .failed: Color(nsColor: .systemRed)
        }
    }
}
