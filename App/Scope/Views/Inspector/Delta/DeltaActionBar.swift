import SwiftUI
import ScopeGit
import ScopeTasks

/// Bottom bar of the Delta panel: Commit… (prominent), Push, Create PR / Open PR, and a caption naming
/// the repo the actions apply to. `gh` missing disables Create PR with a tooltip.
struct DeltaActionBar: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @Binding var showCommitSheet: Bool

    var body: some View {
        let delta = model.delta
        let repo = delta.focusedRepo
        HStack(spacing: 8) {
            Button {
                showCommitSheet = true
            } label: {
                Label("Commit…", systemImage: "circle.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(repo == nil || delta.isActing || !isDirty(repo))
            .help(isDirty(repo) ? "git add -A && git commit in the sandbox" : "Nothing to commit")

            Button {
                Task { await model.delta.push(task: task) }
            } label: {
                Label("Push", systemImage: "arrow.up.to.line")
            }
            .disabled(repo == nil || delta.isActing)
            .help("git push -u origin \(task.branch)")

            if let repo, let url = task.record.pullRequest?.url ?? delta.prURLs[repo.repoRelativePath] {
                Button {
                    model.delta.openPR(url)
                } label: {
                    Label("Open PR", systemImage: "arrow.triangle.pull")
                }
                .help(url.absoluteString)
                pullRequestActions
            } else {
                Button {
                    Task { await model.delta.createPR(task: task) }
                } label: {
                    Label("Create PR", systemImage: "arrow.triangle.pull")
                }
                .disabled(repo == nil || delta.isActing || delta.gh == nil)
                .help(delta.gh == nil ? "gh is not installed (brew install gh)" : "gh pr create for \(task.branch)")
            }

            Spacer(minLength: 4)
            Text(caption(repo))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .controlSize(.small)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Color("PanelBackground"))
    }

    /// Merge when GitHub says the pull request merges, Fix Conflicts when it says it does not; nothing while its
    /// mergeability is unknown or once it is merged.
    @ViewBuilder private var pullRequestActions: some View {
        if let pr = model.livePullRequest(for: task), pr.state == .open {
            switch pr.mergeable {
            case .conflicting:
                ThreadPicker(task: task, title: "Fix Conflicts", systemImage: "arrow.triangle.merge", showsTitle: true) { thread in
                    model.askToFixConflicts(of: task, to: thread)
                }
            case .mergeable:
                Button {
                    Task { await model.mergePullRequest(of: task) }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .disabled(pr.isDraft || model.pullRequests.merging.contains(task.id))
                .help(pr.isDraft ? "A draft cannot be merged" : "gh pr merge #\(pr.number) into \(pr.baseRefName)")
            case .unknown:
                EmptyView()
            }
        }
    }

    private func isDirty(_ repo: TaskRepo?) -> Bool {
        guard let repo else { return false }
        return task.summary(for: repo)?.isDirty ?? true
    }

    private func caption(_ repo: TaskRepo?) -> String {
        guard let repo else { return "" }
        let name = repo.isScopeRoot ? task.record.scopeName : repo.name
        switch task.summary(for: repo)?.sandbox {
        case .dirty(let count): return "\(name) · \(count) uncommitted"
        case .missing: return "\(name) · sandbox missing"
        default: return "\(name) · clean"
        }
    }
}
