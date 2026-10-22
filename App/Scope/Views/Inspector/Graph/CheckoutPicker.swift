import SwiftUI
import ScopeTasks

/// "Open in Editor" for a repo of the graph (spec §4.8): a plain link when the repo has only its base
/// checkout, a menu listing the base and every task sandbox (branch, clean / dirty) otherwise.
struct CheckoutPicker: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let repo: RepoState
    /// The glyph alone, for a card's hover bar; the link with its label otherwise.
    var iconOnly = false

    var body: some View {
        let sandboxes = model.sandboxes(of: repo, in: scope)
        Group {
            if sandboxes.isEmpty {
                if iconOnly {
                    Button {
                        model.openInEditorOrCopy(path: repo.url.path)
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel("Open in Editor")
                } else {
                    Button {
                        model.openInEditorOrCopy(path: repo.url.path)
                    } label: {
                        Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.scopeLink)
                }
            } else {
                ScopeMenu {
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
                } label: { hovering in
                    ScopeLinkLabel(hovering: hovering) {
                        if iconOnly {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        } else {
                            Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                }
                .accessibilityLabel("Open in Editor")
                .fixedSize()
            }
        }
        .help("Open in Editor · ⌥-click copies the path")
    }

    private func state(_ task: TaskState, _ repo: TaskRepo) -> String {
        switch task.summary(for: repo)?.sandbox {
        case .dirty(let count): "\(count) uncommitted"
        case .missing: "missing"
        default: "clean"
        }
    }
}
