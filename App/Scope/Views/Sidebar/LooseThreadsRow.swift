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
        HStack(spacing: 7) {
            Button {
                scope.looseThreadsShown.toggle()
                model.expansionChanged()
            } label: {
                Image(systemName: scope.looseThreadsShown ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.iconTight)
            .help(scope.looseThreadsShown ? "Collapse" : "Expand")
            .accessibilityLabel(scope.looseThreadsShown ? "Collapse loose threads" : "Expand loose threads")

            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text("Loose threads")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)

            if let state = aggregateState {
                StateDot(state: state)
            } else {
                Color.clear.frame(width: 8, height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help("Threads of \(scope.name) that belong to no task: the scope root and the repository base checkouts")
        .accessibilityLabel("Loose threads, \(count)")
    }

    /// The most urgent state among the group's threads, on the same ladder as `TaskRow`.
    private var aggregateState: ThreadState? {
        let states = model.scopeLevelThreads(in: scope.id).map(\.displayState)
        guard !states.isEmpty else { return nil }
        if let waiting = states.first(where: \.needsAttention) { return waiting }
        if states.contains(.running) { return .running }
        if states.contains(.done) { return .done }
        if states.contains(.idle) { return .idle }
        return .exited
    }
}
