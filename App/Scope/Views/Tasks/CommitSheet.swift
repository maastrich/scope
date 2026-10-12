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
        SheetChrome(title: "Commit in \(repo.isScopeRoot ? task.record.scopeName : repo.name)") {
            SheetGroup {
                SheetRow("Branch") {
                    Text(repo.branch)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SheetRow("Message") {
                    TextField("Message", text: $message, prompt: Text("Describe the change"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...8)
                        .font(.scopeValue)
                        .focused($messageFocused)
                        .scopeTextBox(focused: messageFocused)
                }
                Text("git add -A && git commit in the sandbox")
                    .font(.scopeValue)
                    .foregroundStyle(Ink.tertiary)
            }
        } notice: {
        } actions: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.scopeSecondary)
            Button("Commit") {
                onCommit(trimmedMessage)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.scopePrimary)
            .disabled(trimmedMessage.isEmpty)
        }
        .frame(width: 460)
        .onAppear { messageFocused = true }
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
