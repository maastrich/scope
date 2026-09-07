import SwiftUI

/// Task selected, no thread in it yet: "No thread in *task*" + "Open a shell here (⌘T)" + a driver picker.
/// Threads opened here run in the task's sandbox with SCOPE_TASK / SCOPE_TASK_ROOT injected.
struct TaskEmptyView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            (Text("No thread in ") + Text(task.name).italic())
                .font(.system(size: 20, weight: .semibold))
            Text("Threads run in \(task.record.threadCwd.path) on \(task.branch), with SCOPE_TASK and SCOPE_TASK_ROOT injected.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 8) {
                Button {
                    Task { _ = await model.newThread(in: task.scopeID, taskID: task.id) }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open a shell here")
                        Text("⌘T").foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)

                Menu("Other driver…") {
                    ForEach(model.drivers.profiles) { profile in
                        Button(profile.name) {
                            Task { _ = await model.newThread(in: task.scopeID, driverID: profile.id, taskID: task.id) }
                        }
                    }
                }
                .fixedSize()
                .disabled(model.drivers.profiles.isEmpty)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
