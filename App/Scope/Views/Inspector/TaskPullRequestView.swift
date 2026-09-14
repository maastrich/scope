import SwiftUI
import ScopeGit
import ScopeTasks

/// The Pull Request inspector panel: the pull request the selected task is bound to — title and number, its
/// state, review decision and merge state, `head → base` — and every check of its rollup, failures first, each
/// with a link to its page and, for a failing one, **Send to Thread**. No task, or a task without a pull request,
/// gets the matching empty state. The band above keeps the checks fresh.
struct TaskPullRequestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let task = model.currentTask {
            if let linked = task.record.pullRequest {
                content(task: task, linked: linked)
            } else {
                ContentUnavailableView {
                    Label("No pull request", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("Create one from the Delta panel, or push the branch and open it on GitHub: Scope binds the task to it.")
                }
            }
        } else {
            ContentUnavailableView {
                Label("No task", systemImage: "arrow.triangle.pull")
            } description: {
                Text("Select a task or one of its threads to see its pull request and checks.")
            }
        }
    }

    private func content(task: TaskState, linked: LinkedPullRequest) -> some View {
        let live = model.livePullRequest(for: task)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(linked.label)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(live?.title ?? linked.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Button {
                        model.openOnGitHub(linked.url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .cursor(.pointingHand)
                    .help("Open on GitHub — \(linked.url.absoluteString)")
                    .accessibilityLabel("Open pull request \(linked.label) on GitHub")
                    Button {
                        Task { await model.refreshTaskPullRequest(task) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh (automatic every minute)")
                }
                if let live {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(live.headRefName) → \(live.baseRefName)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(live.author)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        if live.state != .open {
                            PullRequestChip(text: live.state == .merged ? "Merged" : "Closed",
                                            color: live.state == .merged ? PullRequestStyle.passing : .secondary)
                        }
                        if live.isDraft {
                            PullRequestChip(text: "Draft", color: .secondary)
                        }
                        if let review = PullRequestStyle.review(live.reviewDecision) {
                            PullRequestChip(text: review.text, color: review.color)
                        }
                        if live.checks != .none {
                            PullRequestChip(text: "\(PullRequestStyle.glyph(live.checks)) \(Self.caption(live.checks))",
                                            color: PullRequestStyle.color(live.checks))
                        }
                        if live.mergeable == .conflicting {
                            PullRequestChip(text: "Conflicts", color: PullRequestStyle.failing)
                        }
                        Spacer(minLength: 0)
                        Text(live.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                } else if let error = model.pullRequests.taskPullRequestErrors[task.id] {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color("WarningText"))
                        .lineLimit(3)
                        .help(error)
                } else {
                    ProgressView("Loading…")
                        .controlSize(.small)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            Divider()
            if let live, !live.checkRuns.isEmpty {
                TaskPullRequestPanel(task: task, pullRequest: live, layout: .full)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            } else if live != nil {
                Text("No checks on this pull request.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(14)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The folded checks state in words, for the chip here and the one on the band.
    static func caption(_ checks: PullRequest.Checks) -> String {
        switch checks {
        case .passing: "checks passed"
        case .failing: "checks failing"
        case .pending: "checks running"
        case .none: ""
        }
    }
}
