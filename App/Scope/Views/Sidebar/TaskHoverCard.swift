import SwiftUI
import ScopeGit
import ScopeTasks

/// What a task row says when the pointer rests on it: the status in a sentence, then the branch, the repositories
/// with their `+N −M`, the pull request and its checks, the task it was started from and those started from it, the
/// age and the prompt. The row itself carries one glyph and a name; everything else waits here, or in the inspector's
/// summary band.
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
                    .font(.scopeTitle)
                    .lineLimit(2)
            }
            Text(TaskStatus.summary(status, facts: facts))
                .font(.scopeRow)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            row("Branch") {
                Text(task.branch)
                    .font(.scopeValue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(task.activeRepos) { repo in
                row(repo.isScopeRoot ? task.record.scopeName : repo.name) {
                    HStack(spacing: 6) {
                        Text(sandboxCaption(repo))
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                        DeltaCounts(additions: task.summary(for: repo)?.additions ?? 0,
                                    deletions: task.summary(for: repo)?.deletions ?? 0)
                    }
                }
            }
            if let pr = task.record.pullRequest {
                row(pr.label) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.title)
                            .font(.scopeCaption)
                            .lineLimit(2)
                        if let checks = facts.pullRequest?.checks, checks != .none {
                            PullRequestChecksLabel(checks: checks, checkedAt: model.pullRequestCheckedAt(for: task))
                                .font(.scopeCaption)
                        }
                    }
                }
            }
            if let setup = setupCaption {
                row("Setup") {
                    Text(setup)
                        .font(.scopeCaption)
                        .foregroundStyle(task.record.setupState == .failed ? AnyShapeStyle(PullRequestStyle.failing) : AnyShapeStyle(.secondary))
                }
            }
            if let topic = task.record.topic {
                row("Topic") {
                    Text(topic)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            if let parent = task.record.parentTask {
                row("From") {
                    Text(model.task(parent).map { "the task “\($0.name)”" } ?? "a task since closed")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            let children = model.childTasks(of: task)
            if !children.isEmpty {
                row("Started") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { child in
                            HStack(spacing: 4) {
                                TaskStatusGlyph(status: TaskStatus.resolve(model.taskFacts(for: child)), size: 10)
                                Text(child.name)
                                    .font(.scopeCaption)
                                    .foregroundStyle(Ink.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            TaskTokensHoverRow(task: task)
            row("Created") {
                Text(task.record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
            if let prompt = task.record.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Divider()
                Text(prompt)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
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
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var setupCaption: String? {
        switch task.record.setupState {
        case .notRun: nil
        case .running: "running…"
        case .succeeded: "done"
        case .failed: "failed — see the Problem Center"
        case .skipped: "skipped"
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

}
