import SwiftUI
import ScopeControl
import ScopeTasks

/// A task's tokens, all told, beside its name in the inspector band: `3.4M tokens`. Nothing for a task none of whose
/// threads Scope read a Claude Code transcript for.
struct TaskTokenBadge: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        if let row = model.tokenUsage.snapshot.tasks[task.record.id.rawValue], !row.total.isZero {
            Text(TokenUsageText.compact(row.total.total) + " tokens")
                .font(.scopeCaption.monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help("Tokens its threads consumed: \(TokenUsageText.compact(row.windows.fiveHours.counts.total)) in the last 5 hours, \(TokenUsageText.compact(row.total.total)) all told")
        }
    }
}

/// The same, as a row of the task's hover card, laid out like the card's own rows.
struct TaskTokensHoverRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        if let row = model.tokenUsage.snapshot.tasks[task.record.id.rawValue], !row.total.isZero {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Tokens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 64, alignment: .leading)
                Text("\(TokenUsageText.compact(row.total.total)) · \(TokenUsageText.compact(row.windows.fiveHours.counts.total)) in 5h")
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
