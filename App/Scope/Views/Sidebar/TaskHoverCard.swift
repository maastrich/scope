import SwiftUI
import ScopeGit
import ScopeTasks

/// What a task row says when the pointer rests on it: the status in a sentence, then the branch, the repositories
/// with their `+N −M`, the pull request and its checks, the age and the prompt. The row itself carries one glyph and
/// a name; everything else waits here, or in the inspector's summary band.
struct TaskHoverCard: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let status: TaskStatus
    let facts: TaskFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TaskStatusGlyph(status: status)
                Text(task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            Text(TaskStatus.summary(status, facts: facts))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            row("Branch") {
                Text(task.branch)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(task.activeRepos) { repo in
                row(repo.isScopeRoot ? task.record.scopeName : repo.name) {
                    HStack(spacing: 6) {
                        Text(sandboxCaption(repo))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        DeltaCounts(additions: task.summary(for: repo)?.additions ?? 0,
                                    deletions: task.summary(for: repo)?.deletions ?? 0)
                    }
                }
            }
            if let pr = task.record.pullRequest {
                row(pr.label) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.title)
                            .font(.system(size: 11))
                            .lineLimit(2)
                        if let checks = facts.pullRequest?.checks, checks != .none {
                            Text("\(PullRequestStyle.glyph(checks)) \(checksCaption(checks))")
                                .font(.system(size: 11))
                                .foregroundStyle(PullRequestStyle.color(checks))
                        }
                    }
                }
            }
            row("Created") {
                Text(task.record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let prompt = task.record.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Divider()
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func sandboxCaption(_ repo: TaskRepo) -> String {
        switch task.summary(for: repo)?.sandbox {
        case .none: "…"
        case .clean: "clean"
        case .dirty(let count): "\(count) uncommitted"
        case .missing: "sandbox missing"
        }
    }

    private func checksCaption(_ checks: PullRequest.Checks) -> String {
        switch checks {
        case .passing: "checks passed"
        case .failing: "checks failing"
        case .pending: "checks running"
        case .none: ""
        }
    }
}
