import SwiftUI
import ScopeCore

/// The group row the scope-level and repo-base threads hang under, at the depth of a task.
///
/// It replaces the old **Threads** section: the same object used to be a child of a task in one place and a
/// top-level row in another, so finding a thread meant remembering where it was born. The row is not selectable —
/// there is nothing to show for "the threads that belong to no task" — it only expands and collapses, and carries
/// the aggregated state dot of its children so a collapsed group never hides a thread that wants you.
struct LooseThreadsRow: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let count: Int

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            SidebarDisclosure(
                isExpanded: scope.looseThreadsShown,
                accessibilityLabel: scope.looseThreadsShown ? "Collapse loose threads" : "Expand loose threads"
            ) {
                scope.looseThreadsShown.toggle()
                model.expansionChanged()
            }

            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .frame(width: SidebarMetrics.glyphSlot)

            Text("Loose threads")
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text("\(count)")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)

            SidebarStateDot(state: aggregateState, pulses: aggregateIsWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: false))
        .contentShape(Rectangle())
        .help("Threads of \(scope.name) that belong to no task: the scope root and the repository base checkouts")
        .accessibilityLabel("Loose threads, \(count)")
        .sidebarRow(selected: false)
    }

    /// The most urgent state among the threads (`ThreadState.mostUrgent`).
    private var aggregateState: ThreadState? {
        ThreadState.mostUrgent(model.scopeLevelThreads(in: scope.id).map(\.displayState))
    }

    /// Breathes when the aggregate is `running` because a driver says so.
    private var aggregateIsWorking: Bool {
        model.scopeLevelThreads(in: scope.id).contains(where: \.isWorking)
    }
}
