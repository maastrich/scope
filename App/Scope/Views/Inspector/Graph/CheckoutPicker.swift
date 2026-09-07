import SwiftUI
import ScopeTasks

/// "Open in Editor" for a repo of the graph (spec §4.8): a plain link when the repo has only its base
/// checkout, a menu listing the base and every task sandbox (branch, clean / dirty) otherwise.
struct CheckoutPicker: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let repo: RepoState

    var body: some View {
        let sandboxes = model.sandboxes(of: repo, in: scope)
        let disabled = model.config.preferences.editor == nil
        Group {
            if sandboxes.isEmpty {
                Button {
                    model.openInEditorOrCopy(path: repo.url.path)
                } label: {
                    Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.link)
            } else {
                Menu {
                    Button {
                        model.openInEditorOrCopy(path: repo.url.path)
                    } label: {
                        Text("Base · \(repo.branchLabel ?? "")\(repo.isDirty ? " · dirty" : "")")
                    }
                    Divider()
                    ForEach(sandboxes, id: \.task.id) { entry in
                        Button {
                            model.openInEditorOrCopy(path: entry.repo.sandboxPath)
                        } label: {
                            Text("\(entry.task.name) · \(entry.repo.branch) · \(state(entry.task, entry.repo))")
                        }
                    }
                } label: {
                    Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .menuStyle(.button)
                .buttonStyle(.link)
                .fixedSize()
            }
        }
        .disabled(disabled)
        .help(disabled ? "Choose an editor in Settings" : "⌥-click copies the path")
    }

    private func state(_ task: TaskState, _ repo: TaskRepo) -> String {
        switch task.summary(for: repo)?.sandbox {
        case .dirty(let count): "\(count) uncommitted"
        case .missing: "missing"
        default: "clean"
        }
    }
}
