import SwiftUI

/// Task selected, no thread in it yet: "No thread in *task*" + "Open a shell here (⌘T)" + a driver picker.
/// Threads opened here run in the task's sandbox with SCOPE_TASK / SCOPE_TASK_ROOT injected.
///
/// An archived task has no sandbox to run in: the view offers Restore instead, which shows it working and ignores
/// clicks until the restore is over. A task whose sandbox went missing offers nothing to open.
struct TaskEmptyView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    private var sandboxMissing: Bool { !ScopeState.rootExists(task.record.threadCwd) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: task.isArchived ? "archivebox" : "arrow.triangle.branch")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Ink.tertiary)
            (Text(task.isArchived ? "Archived: " : "No thread in ") + Text(task.name).italic())
                .font(.system(size: 20, weight: .semibold))
            Text(explanation)
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if task.isArchived {
                restoreButton
            } else if !sandboxMissing {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.newThreadInCurrentContext() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Open a shell here")
                            Text("⌘T").foregroundStyle(.white.opacity(0.7))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.scopePrimary)
                    .usageID("task-empty.new-thread", label: "Open a shell here (empty task)")

                    ScopeMenu("Other driver…") {
                        ForEach(model.drivers.profiles) { profile in
                            Button(profile.name) {
                                Task { await model.newThreadInCurrentContext(driverID: profile.id) }
                            }
                        }
                    }
                    .disabled(model.drivers.profiles.isEmpty)
                    .usageID("task-empty.other-driver", label: "Other driver (empty task)")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.ground)
    }

    private var explanation: String {
        if task.isArchived {
            return "Its worktrees were removed and its branch \(task.branch) kept. Restore it to work in it again."
        }
        if sandboxMissing {
            return "Its sandbox \(task.record.threadCwd.path) is missing: nothing can run in it."
        }
        return "Threads run in \(task.record.threadCwd.path) on \(task.branch), with SCOPE_TASK and SCOPE_TASK_ROOT injected."
    }

    private var restoreButton: some View {
        let restoring = model.restoringTasks.contains(task.id)
        return Button {
            Task { await model.reopenTask(task.id) }
        } label: {
            HStack(spacing: 6) {
                if restoring {
                    ProgressView().controlSize(.small)
                    Text("Restoring…")
                } else {
                    Text("Restore Task")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.scopePrimary)
        .disabled(restoring)
        .usageID("task-empty.restore", label: "Restore (archived task)")
    }
}
