import SwiftUI
import ScopeTasks

/// The block shown under the selected task row: the branch line, the pull request line (when bound) and one row per repo with the
/// sandbox state, `+N −M`, a state dot, and (on hover) Open in Editor / Show Delta buttons.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(task.branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: 20)
            if let pr = task.record.pullRequest {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("\(pr.label) \(pr.title)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button {
                        model.openOnGitHub(pr.url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open on GitHub — \(pr.url.absoluteString)")
                }
                .frame(height: 20)
            }
            ForEach(task.activeRepos) { repo in
                TaskRepoRow(task: task, repo: repo)
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 2)
        .padding(.bottom, 4)
        .selectionDisabled()
    }
}

private struct TaskRepoRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(repo.isScopeRoot ? task.record.scopeName : repo.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    model.openInEditorOrCopy(path: repo.sandboxPath)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in Editor (⌥-click copies the path)")
                Button {
                    model.selection = .task(task.id)
                    model.inspectorTab = .delta
                    model.inspectorShown = true
                    model.delta.selectedFile = model.delta.orderedFiles.first { $0.repo == repo.repoRelativePath }
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("See Delta (⌘D)")
            }
            Text(stateCaption)
                .font(.system(size: 10.5))
                .foregroundStyle(stateIsWarning ? AnyShapeStyle(ThreadStateStyle.waiting) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            DeltaCounts(additions: summary?.additions ?? 0, deletions: summary?.deletions ?? 0)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(repo.sandboxPath)
    }

    private var summary: RepoDeltaSummary? { task.summary(for: repo) }

    private var stateCaption: String {
        switch summary?.sandbox {
        case .none: "…"
        case .clean: "clean"
        case .dirty(let count): "\(count) uncommitted"
        case .missing: "missing"
        }
    }

    private var stateIsWarning: Bool {
        switch summary?.sandbox {
        case .dirty, .missing: true
        default: false
        }
    }

    private var dotColor: Color {
        switch summary?.sandbox {
        case .dirty: ThreadStateStyle.waiting
        case .missing: Color(nsColor: .systemRed)
        case .clean: ThreadStateStyle.done
        case .none: ThreadStateStyle.idle
        }
    }
}

/// `+N` green / `−N` red, mono 11, zero values omitted (design §3).
struct DeltaCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11

    static let added = Color(red: 0.122, green: 0.616, blue: 0.247)
    static let removed = Color(red: 0.851, green: 0.188, blue: 0.145)

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 {
                Text("+\(additions)").foregroundStyle(Self.added)
            }
            if deletions > 0 {
                Text("−\(deletions)").foregroundStyle(Self.removed)
            }
        }
        .font(.system(size: size, design: .monospaced))
    }
}
