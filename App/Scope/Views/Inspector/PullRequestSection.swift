import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// The Pull Request section: closed, the number and the state of the checks — or, with several pull requests,
/// `2 PRs · 1 merged · 1 checks failing`; open, every pull request the selected task is bound to, one row each
/// (repository, number, title, state, checks, review), then the detail of the one picked — title, `head → base`,
/// state, review and merge chips — and every check of its rollup, failures first, each with a link to its page and,
/// for a failing one, **Send to Thread**. The pick is explicit and kept per task; without one the primary
/// (`PullRequestSet.primary`) is shown, and every button of the header acts on the pull request on show.
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
            if let task, let link = model.selectedPullRequest(for: task), let pr = model.livePullRequest(for: task, link: link),
               pr.state == .open, pr.mergeable == .conflicting {
                ThreadPicker(task: task, title: "Fix Conflicts", systemImage: "arrow.triangle.merge", showsTitle: true) { thread in
                    model.askToFixConflicts(of: task, pullRequest: link, to: thread)
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
        let facts = model.pullRequestFacts(for: task)
        if let caption = PullRequestSet.caption(facts) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.scopeValue)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let checkedAt = model.pullRequestCheckedAt(for: task) {
                    PullRequestReadAge(checkedAt: checkedAt)
                }
            }
            .help(facts.map { "#\($0.number) \($0.state.rawValue)" }.joined(separator: " · "))
        } else if let linked = task.record.primaryPullRequest {
            let live = model.livePullRequest(for: task, link: linked)
            let checks = live?.checks ?? .none
            HStack(spacing: 6) {
                Text(linked.label)
                    .font(.scopeValue)
                if let live, live.state != .open {
                    Text(live.state == .merged ? "merged" : "closed")
                } else if live == nil, !linked.isOpen {
                    Text(linked.state ?? "")
                } else if live?.isDraft == true {
                    Text("draft")
                }
                if checks != .none {
                    PullRequestChecksLabel(checks: checks, checkedAt: model.pullRequestCheckedAt(for: task, link: linked))
                }
            }
        } else if let issue = task.record.issue {
            HStack(spacing: 6) {
                Text("none yet")
                    .foregroundStyle(Ink.tertiary)
                Text("for issue \(issue.label)")
                    .foregroundStyle(Ink.tertiary)
            }
        } else {
            Text("none yet")
                .foregroundStyle(Ink.tertiary)
        }
    }

    /// The issue the task works on, over the pull request (or over its absence): a link to its page.
    @ViewBuilder
    private func issueRow(_ issue: LinkedIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 10))
                .foregroundStyle(Ink.tertiary)
            Text("Issue \(issue.label)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Ink.secondary)
            Text(issue.title)
                .font(.scopeCaption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                model.openOnGitHub(issue.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.secondary)
            .help("Open issue \(issue.label) on GitHub — \(issue.url.absoluteString)")
            .accessibilityLabel("Open issue \(issue.label) on GitHub")
            .usageID("open-issue", label: "Open the task's issue")
        }
    }

    @ViewBuilder
    private func actions(_ task: TaskState) -> some View {
        let acts = model.config.preferences.showGitActions
        let selected = model.selectedPullRequest(for: task)
        if let url = selected?.url ?? model.delta.focusedRepo.flatMap({ model.delta.prURLs[$0.repoRelativePath] }) {
            Button {
                model.openOnGitHub(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .cursor(.pointingHand)
            .help("Open \(selected?.label ?? "the pull request") on GitHub — \(url.absoluteString)")
            .accessibilityLabel("Open \(selected?.label ?? "the pull request") on GitHub")
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
        if acts, let selected, let pr = model.livePullRequest(for: task, link: selected), pr.state == .open, pr.mergeable == .mergeable {
            Button {
                Task { await model.mergePullRequest(of: task, pullRequest: selected) }
            } label: {
                Image(systemName: "arrow.triangle.merge")
            }
            .disabled(pr.isDraft || model.pullRequests.merging.contains(task.id))
            .help(pr.isDraft ? "A draft cannot be merged" : "Merge — gh pr merge #\(pr.number) into \(pr.baseRefName)")
            .accessibilityLabel("Merge \(selected.label)")
        }
        if !task.record.pullRequests.isEmpty {
            Button {
                Task { await model.refreshTaskPullRequest(task) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (every minute while on screen, every 5 minutes otherwise)")
            .accessibilityLabel("Refresh the pull requests")
        }
    }

    // MARK: Body

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        if let selected = model.selectedPullRequest(for: task) {
            VStack(alignment: .leading, spacing: 6) {
                if let issue = task.record.issue { issueRow(issue) }
                if task.record.pullRequests.count > 1 {
                    PullRequestList(task: task, selected: selected)
                    Divider()
                        .padding(.vertical, 2)
                }
                detail(task, selected)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let issue = task.record.issue { issueRow(issue) }
                Text(task.record.issue == nil
                     ? "No pull request yet. Push the branch and open one — from the thread or on GitHub — and Scope binds the task to it."
                     : "No pull request yet. The one that closes the issue should say so (Closes \(task.record.issue?.label ?? "")); Scope binds the task to it.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                lagLine(task)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }

    /// One pull request in full: what the record keeps, then what `gh` last said of it.
    @ViewBuilder
    private func detail(_ task: TaskState, _ linked: LinkedPullRequest) -> some View {
        let live = model.livePullRequest(for: task, link: linked)
        let several = task.record.pullRequests.count > 1
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if several, let repo = model.repo(of: linked, in: task) {
                Text(repo.name)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Text(linked.label)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Ink.secondary)
            Text(live?.title ?? linked.title)
                .font(.scopeCaption)
                .lineLimit(2)
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
                PullRequestReadAge(checkedAt: model.pullRequestCheckedAt(for: task, link: linked))
                    .font(.system(size: 10.5))
            }
            lagLine(task)
            if !live.checkRuns.isEmpty {
                TaskPullRequestPanel(task: task, pullRequest: live, link: linked, layout: .full)
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

    /// `behind main by 4 · conflicts in 2 files`, as the background pass last measured it, with the hold when the
    /// user set one. Red when conflicts, otherwise the quiet grey of a fact.
    @ViewBuilder
    private func lagLine(_ task: TaskState) -> some View {
        if let lag = model.lag(of: task), let caption = lag.caption {
            HStack(spacing: 6) {
                Image(systemName: lag.hasConflicts ? "exclamationmark.triangle" : (lag.isBehind ? "arrow.triangle.branch" : "checkmark"))
                    .font(.system(size: 10))
                Text(caption + (task.record.holdBranch ? " · held" : ""))
                    .font(.scopeCaption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                PullRequestReadAge(checkedAt: lag.repos.values.map(\.checkedAt).min())
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(lag.hasConflicts ? PullRequestStyle.failing : Ink.secondary)
            .help(lag.conflictedPaths.isEmpty ? "The branch against \(lag.upstream), fetched by the background refresh"
                                              : "Conflicts: " + lag.conflictedPaths.joined(separator: ", "))
            .accessibilityLabel("Branch against main: \(caption)")
        }
    }
}

/// Every pull request of a task, one row each: the repository (when the task spans several), the number, the
/// title, then what GitHub says — merged, closed, draft, the checks as a glyph, the review — in the task's own order
/// (`PullRequestSet.ordered`: repositories first, then numbers), which never moves with the states. A click picks
/// the one the detail below and the header's buttons act on; the pick is kept per task.
struct PullRequestList: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let selected: LinkedPullRequest

    var body: some View {
        let several = Set(task.record.pullRequests.compactMap(\.repo)).count > 1 || task.record.repos.count > 1
        VStack(alignment: .leading, spacing: 1) {
            ForEach(task.record.pullRequests) { link in
                row(link, named: several, isSelected: link.url == selected.url)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.record.pullRequests.count) pull requests")
    }

    private func row(_ link: LinkedPullRequest, named: Bool, isSelected: Bool) -> some View {
        let live = model.livePullRequest(for: task, link: link)
        let state = live?.state ?? link.state.flatMap(PullRequest.State.init(rawValue:)) ?? .open
        let checks = live?.checks ?? .none
        return Button {
            model.selectPullRequest(link, for: task)
        } label: {
            HStack(spacing: 6) {
                if named, let repo = model.repo(of: link, in: task) {
                    Text(repo.name)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(link.label)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize()
                Text(live?.title ?? link.title)
                    .font(.scopeCaption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if state != .open {
                    PullRequestChip(text: state == .merged ? "Merged" : "Closed",
                                    color: state == .merged ? PullRequestStyle.passing : .secondary)
                } else if live?.isDraft == true {
                    PullRequestChip(text: "Draft", color: .secondary)
                } else if live?.mergeable == .conflicting {
                    PullRequestChip(text: "Conflicts", color: PullRequestStyle.failing)
                } else if let review = live.flatMap({ PullRequestStyle.review($0.reviewDecision) }) {
                    PullRequestChip(text: review.text, color: review.color)
                }
                if checks != .none {
                    Text(PullRequestStyle.glyph(checks))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PullRequestStyle.color(checks))
                        .frame(width: 12)
                        .accessibilityLabel("checks \(checks.rawValue)")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("\(link.label) \(live?.title ?? link.title) — \(state.rawValue)" + (checks == .none ? "" : ", checks \(checks.rawValue)"))
        .accessibilityLabel("\(link.label) \(live?.title ?? link.title), \(state.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
