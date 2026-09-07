import SwiftUI
import ScopeTasks

/// *Commit…* from the Delta action bar: message pre-filled with the task name, the repo and branch shown.
struct CommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: TaskState
    let repo: TaskRepo
    let onCommit: @MainActor (String) -> Void
    @State private var message: String

    init(task: TaskState, repo: TaskRepo, onCommit: @escaping @MainActor (String) -> Void) {
        self.task = task
        self.repo = repo
        self.onCommit = onCommit
        _message = State(initialValue: task.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit in \(repo.isScopeRoot ? task.record.scopeName : repo.name)")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(repo.branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("git add -A && git commit")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $message)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") {
                    onCommit(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
