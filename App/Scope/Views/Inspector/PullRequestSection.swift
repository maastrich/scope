import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// The Pull Request section: closed, the number and the state of the checks; open, the pull request the selected task
/// is bound to — title, `head → base`, state, review and merge chips — and every check of its rollup, failures first,
/// each with a link to its page and, for a failing one, **Send to Thread**.
///
/// The header carries what used to be the Delta action bar's pull request buttons: Fix Conflicts stays visible while
/// GitHub reports a conflict (it is the thing to do next), Open on GitHub, Refresh and — with Settings ▸ Git ▸ Show
/// commit and push buttons — Create PR and Merge come on hover.
struct PullRequestSection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .pullRequest, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } accessories: {
            if let task, let pr = model.livePullRequest(for: task), pr.state == .open, pr.mergeable == .conflicting {
                ThreadPicker(task: task, title: "Fix Conflicts", systemImage: "arrow.triangle.merge", showsTitle: true) { thread in
                    model.askToFixConflicts(of: task, to: thread)
                }
            }
        } actions: {
            if let task { actions(task) }
        } content: {
            if let task { content(task) }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        if let linked = task.record.pullRequest {
            let live = model.livePullRequest(for: task)
            let checks = live?.checks ?? model.liveChecks(for: task) ?? .none
            HStack(spacing: 6) {
                Text(linked.label)
                    .font(.scopeValue)
                if let live, live.state != .open {
                    Text(live.state == .merged ? "merged" : "closed")
                } else if live?.isDraft == true {
                    Text("draft")
                }
                if checks != .none {
                    Text("\(PullRequestStyle.glyph(checks)) \(Self.caption(checks))")
                        .foregroundStyle(PullRequestStyle.color(checks))
                }
            }
        } else {
            Text("none yet")
                .foregroundStyle(Ink.tertiary)
        }
    }

    @ViewBuilder
    private func actions(_ task: TaskState) -> some View {
        let acts = model.config.preferences.showGitActions
        if let url = task.record.pullRequest?.url ?? model.delta.focusedRepo.flatMap({ model.delta.prURLs[$0.repoRelativePath] }) {
            Button {
                model.openOnGitHub(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .cursor(.pointingHand)
            .help("Open on GitHub — \(url.absoluteString)")
            .accessibilityLabel("Open the pull request on GitHub")
        } else if acts {
            Button {
                Task { await model.delta.createPR(task: task) }
            } label: {
                Image(systemName: "arrow.triangle.pull")
            }
            .disabled(model.delta.focusedRepo == nil || model.delta.isActing || model.delta.gh == nil)
            .help(model.delta.gh == nil ? "gh is not installed (brew install gh)" : "Create PR — gh pr create for \(task.branch)")
            .accessibilityLabel("Create pull request")
        }
        if acts, let pr = model.livePullRequest(for: task), pr.state == .open, pr.mergeable == .mergeable {
            Button {
                Task { await model.mergePullRequest(of: task) }
            } label: {
                Image(systemName: "arrow.triangle.merge")
            }
            .disabled(pr.isDraft || model.pullRequests.merging.contains(task.id))
            .help(pr.isDraft ? "A draft cannot be merged" : "Merge — gh pr merge #\(pr.number) into \(pr.baseRefName)")
            .accessibilityLabel("Merge the pull request")
        }
        if task.record.pullRequest != nil {
            Button {
                Task { await model.refreshTaskPullRequest(task) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (automatic every minute)")
            .accessibilityLabel("Refresh the pull request")
        }
    }

    // MARK: Body

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        if let linked = task.record.pullRequest {
            let live = model.livePullRequest(for: task)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(linked.label)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Ink.secondary)
                    Text(live?.title ?? linked.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let live {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(live.headRefName) → \(live.baseRefName)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(live.author)
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
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
                        if live.mergeable == .conflicting {
                            PullRequestChip(text: "Conflicts", color: PullRequestStyle.failing)
                        }
                        Spacer(minLength: 0)
                        Text(live.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.tertiary)
                    }
                    if !live.checkRuns.isEmpty {
                        TaskPullRequestPanel(task: task, pullRequest: live, layout: .full)
                            .padding(.top, 2)
                    } else {
                        Text("No checks on this pull request.")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                    }
                } else if let error = model.pullRequests.taskPullRequestErrors[task.id] {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color("WarningText"))
                        .lineLimit(3)
                        .help(error)
                } else {
                    ScopeLoading(text: "Loading…")
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } else {
            Text("No pull request yet. Push the branch and open one — from the thread or on GitHub — and Scope binds the task to it.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }

    /// The folded checks state in words, for the header here and the chip of the task's sidebar row.
    static func caption(_ checks: PullRequest.Checks) -> String {
        switch checks {
        case .passing: "checks passed"
        case .failing: "checks failing"
        case .pending: "checks running"
        case .none: ""
        }
    }
}
