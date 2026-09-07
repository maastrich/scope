import SwiftUI
import ScopeTasks

/// *Commit…* from the Delta action bar: an empty message field with a placeholder, the repo and branch shown.
struct CommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: TaskState
    let repo: TaskRepo
    let onCommit: @MainActor (String) -> Void
    @State private var message = ""
    @FocusState private var messageFocused: Bool

    init(task: TaskState, repo: TaskRepo, onCommit: @escaping @MainActor (String) -> Void) {
        self.task = task
        self.repo = repo
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Branch") {
                        Text(repo.branch)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TextField("Message", text: $message, prompt: Text("Describe the change"), axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($messageFocused)
                } header: {
                    Text("Commit in \(repo.isScopeRoot ? task.record.scopeName : repo.name)")
                } footer: {
                    Text("git add -A && git commit in the sandbox")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") {
                    onCommit(trimmedMessage)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedMessage.isEmpty)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: 460)
        .onAppear { messageFocused = true }
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
