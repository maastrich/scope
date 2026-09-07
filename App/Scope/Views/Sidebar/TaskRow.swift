import SwiftUI
import ScopeCore
import ScopeTasks

/// Sidebar row for a task (depth 1): chevron, branch icon, name, branch chip, `api · web` caption and
/// the aggregated state dot of its threads.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        HStack(spacing: 7) {
            Button {
                task.isExpanded.toggle()
            } label: {
                Image(systemName: task.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(task.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if task.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Text(task.reposCaption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 90)
            if let state = aggregateState {
                StateDot(state: state)
            }
        }
        .padding(.leading, 16)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help("\(task.branch) — \(task.record.root)")
        .contextMenu { TaskContextMenu(task: task) }
    }

    /// The most urgent state among the task's threads: waiting > running > done > idle > exited.
    private var aggregateState: ThreadState? {
        let states = model.threads(in: task.id).map(\.displayState)
        guard !states.isEmpty else { return nil }
        if let waiting = states.first(where: \.needsAttention) { return waiting }
        if states.contains(.running) { return .running }
        if states.contains(.done) { return .done }
        if states.contains(.idle) { return .idle }
        return .exited
    }
}

/// Context menu shared by the task row and the menu bar.
struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        Button("New Thread in Task") {
            Task { _ = await model.newThread(in: task.scopeID, taskID: task.id) }
        }
        Menu("New Thread With Driver") {
            ForEach(model.drivers.profiles) { profile in
                Button(profile.name) {
                    Task { _ = await model.newThread(in: task.scopeID, driverID: profile.id, taskID: task.id) }
                }
            }
        }
        Divider()
        let candidates = model.candidateRepos(for: task)
        Menu("Add Repo…") {
            ForEach(candidates) { repo in
                Button(repo.id) {
                    Task { await model.addRepo(repo.id, to: task.id) }
                }
            }
        }
        .disabled(candidates.isEmpty)
        Button("Open Task in Editor") {
            model.openTaskInEditor(task)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        Button("See Delta") {
            model.selection = .task(task.id)
            model.inspectorTab = .delta
            model.inspectorShown = true
        }
        Divider()
        Button("Reveal in Finder") {
            Reveal.inFinder(task.record.rootURL)
        }
        Button("Copy Task Root Path") {
            Pasteboard.copyPath(task.record.rootURL)
        }
        Button("Refresh") {
            task.refresh()
        }
        Divider()
        Button("Archive") {
            Task { await model.archiveTask(task.id) }
        }
        Button("Close Task…", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: false) }
        }
        Button("Close Task and Delete Branch…", role: .destructive) {
            Task { await model.closeTask(task.id, deleteBranch: true) }
        }
    }
}
