import SwiftUI
import ScopeCore
import ScopeTasks

/// The Context card: what the agent was given and how the task has gone. Closed, the model of the task's thread
/// (or how long the brief is); open, the brief folded to four lines with *Read in full*, the mission checklist when
/// the task is one, and the task's timeline — agent time, time waiting for you, elapsed time, one lane per thread.
struct ContextCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .context, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } actions: {
            if let task, !(task.record.prompt ?? "").isEmpty {
                Button {
                    model.readBrief(of: task)
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Read the brief in full, in the reading column")
                .accessibilityLabel("Read the brief of \(task.name)")
            }
        } content: {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    CardGroupLabel("Brief")
                    TaskBriefExcerpt(task: task)
                    if let mission = task.record.mission {
                        MissionChecklist(task: task, mission: mission)
                    }
                    CardGroupLabel("Timeline · since creation")
                        .padding(.top, 4)
                    TaskTimelineView(task: task)
                        .padding(.top, 4)
                        .usageID("timeline", label: "Task timeline")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        let models = Set(model.threads(in: task.id).compactMap(\.record.model))
        if let name = models.sorted().first {
            Text(name)
        } else {
            let lines = (task.record.prompt ?? "").split(whereSeparator: \.isNewline).count
            Text(lines == 0 ? "no brief" : "brief · \(lines) \(lines == 1 ? "line" : "lines")")
                .foregroundStyle(Ink.tertiary)
        }
    }
}

/// The small uppercase label that heads a group of rows inside a card (*Brief*, *Checkpoints*).
struct CardGroupLabel: View {
    let text: String
    var count: Int? = nil

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.scopeMicro)
                .tracking(0.4)
                .foregroundStyle(Ink.tertiary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
