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
                PullRequestList(task: task, selected: selected)
                detail(task, selected)
                footer(task, selected)
            }
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let issue = task.record.issue { issueRow(issue) }
                CardEmptyState(title: "No pull request yet",
                               detail: task.record.issue == nil
                                   ? "Push the branch and open one — from the thread or on GitHub — and Scope binds the task to it."
                                   : "The one that closes the issue should say so (Closes \(task.record.issue?.label ?? "")); Scope binds the task to it.")
                lagLine(task)
            }
            .padding(EdgeInsets(top: 2, leading: 10, bottom: 6, trailing: 10))
        }
    }

    /// One pull request in full, under its row: `head → base`, author, review and merge chips, the base lag, then
    /// every check of its rollup.
    @ViewBuilder
    private func detail(_ task: TaskState, _ linked: LinkedPullRequest) -> some View {
        let live = model.livePullRequest(for: task, link: linked)
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
                Spacer(minLength: 0)
                Text("updated \(live.updatedAt, format: .relative(presentation: .named))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            .padding(.top, 4)
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

/// The foot of the card: what the pull request on show asks of you, in one line — *Ready to merge*, *2 checks
/// failing*, *Conflicts with the base* (`PullRequestSet.verdict`) — with how old the reading is, and **Ask the agent**
/// when the agent can act on it: fix the conflicts, fix the failing check, merge. *Merge…* itself stays behind
/// Settings ▸ Git, as every git button does: the agent does the git.
extension PullRequestSection {
    @ViewBuilder
    fileprivate func footer(_ task: TaskState, _ linked: LinkedPullRequest) -> some View {
        if let live = model.livePullRequest(for: task, link: linked) {
            let tally = PullRequestSet.tally(live.checkRuns)
            let verdict = PullRequestSet.verdict(state: live.state, isDraft: live.isDraft, mergeable: live.mergeable,
                                                 tally: tally, review: live.reviewDecision)
            let color = Self.color(of: verdict)
            HStack(spacing: 6) {
                Image(systemName: Self.glyph(of: verdict))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(verdict.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                PullRequestReadAge(checkedAt: model.pullRequestCheckedAt(for: task, link: linked))
                    .font(.system(size: 10.5))
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                if verdict.asksTheAgent, !task.isArchived {
                    ThreadPicker(task: task, title: "Ask the agent", systemImage: "paperplane", showsTitle: true) { thread in
                        ask(verdict, of: task, pullRequest: linked, live: live, to: thread)
                    }
                    .fixedSize()
                    .help(Self.askHelp(verdict))
                    .usageID("inspector.pull-requests.ask-agent", label: "Ask the agent about the pull request")
                }
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
        }
    }

    /// Conflicts go back as a merge request, a failure as its log, a green one as a merge to make.
    private func ask(_ verdict: PullRequestSet.Verdict, of task: TaskState, pullRequest link: LinkedPullRequest,
                     live: PullRequest, to thread: ThreadID) {
        switch verdict {
        case .conflicting:
            model.askToFixConflicts(of: task, pullRequest: link, to: thread)
        case .checksFailing:
            if let failed = live.checkRuns.first(where: { $0.state == .failing }) {
                Task { await model.sendCheckFailure(failed, of: task, pullRequest: link, to: thread) }
            }
        case .ready, .reviewNeeded:
            model.askToMerge(of: task, pullRequest: link, to: thread)
        default:
            break
        }
    }

    static func askHelp(_ verdict: PullRequestSet.Verdict) -> String {
        switch verdict {
        case .conflicting: "Ask the agent to bring the base in and resolve the conflicts"
        case .checksFailing: "Send the agent the log of the failing check"
        case .ready, .reviewNeeded: "Ask the agent to merge once nothing is left to push"
        default: "Ask the agent"
        }
    }

    static func glyph(of verdict: PullRequestSet.Verdict) -> String {
        switch verdict {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .conflicting: "exclamationmark.triangle"
        case .checksFailing: "xmark"
        case .changesRequested: "text.bubble"
        case .draft: "pencil.line"
        case .checksRunning: "clock"
        case .reviewNeeded, .ready: "checkmark"
        case .open: "circle"
        }
    }

    static func color(of verdict: PullRequestSet.Verdict) -> Color {
        switch verdict {
        case .merged, .ready: PullRequestStyle.passing
        case .conflicting, .checksFailing, .changesRequested: PullRequestStyle.failing
        case .checksRunning: PullRequestStyle.pending
        case .reviewNeeded: Ink.secondary
        case .closed, .draft, .open: Ink.tertiary
        }
    }
}

/// Every pull request of a task, one compact row each — the shape of the mockups: a state glyph, the title, then
/// `repo #n · +a −d · ✗ 1 / 4 · review` on a second line — in the task's own order (`PullRequestSet.ordered`:
/// repositories first, then numbers), which never moves with the states. A click picks the one the detail below and
/// the header's buttons act on; the pick is kept per task. With a single pull request the row still stands: it is
/// where the number, the title and the counts live.
struct PullRequestList: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let selected: LinkedPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(task.record.pullRequests) { link in
                row(link, branched: task.record.branches.count > 1, isSelected: link.url == selected.url)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.record.pullRequests.count) pull requests")
    }

    /// `branched`: the task works on several branches, so each row says which one its pull request is on.
    private func row(_ link: LinkedPullRequest, branched: Bool, isSelected: Bool) -> some View {
        let live = model.livePullRequest(for: task, link: link)
        let state = live?.state ?? link.state.flatMap(PullRequest.State.init(rawValue:)) ?? .open
        let tally = PullRequestSet.tally(live?.checkRuns ?? [])
        let verdict = PullRequestSet.verdict(state: state, isDraft: live?.isDraft ?? false, mergeable: live?.mergeable ?? .unknown,
                                             tally: tally, review: live?.reviewDecision ?? .none)
        let repoName = model.repo(of: link, in: task)?.name ?? PullRequest.repository(fromURL: link.url)?.split(separator: "/").last.map(String.init)
        return Button {
            model.selectPullRequest(link, for: task)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: PullRequestSection.glyph(of: verdict))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PullRequestSection.color(of: verdict))
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live?.title ?? link.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text([repoName, link.label].compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        if branched, let head = live?.headRefName ?? link.headRefName {
                            Text(head)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(-1)
                        }
                        if let live, live.additions != nil || live.deletions != nil {
                            DeltaCounts(additions: live.additions ?? 0, deletions: live.deletions ?? 0)
                        }
                        if let caption = tally.caption {
                            PullRequestChip(text: caption, color: PullRequestStyle.color(tally.checks))
                        }
                        trailing(state: state, live: live, verdict: verdict)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Fill.selectedTint : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("\(link.label) \(live?.title ?? link.title) — \(verdict.label)")
        .accessibilityLabel("\(link.label) \(live?.title ?? link.title), \(verdict.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The last word of the second line: merged · age, closed, draft, conflicts, or the review decision.
    @ViewBuilder
    private func trailing(state: PullRequest.State, live: PullRequest?, verdict: PullRequestSet.Verdict) -> some View {
        switch state {
        case .merged:
            PullRequestChip(text: live?.mergedAt.map { "merged · \(Self.age($0))" } ?? "merged", color: PullRequestStyle.passing)
        case .closed:
            PullRequestChip(text: "closed", color: .secondary)
        case .open:
            if live?.isDraft == true {
                PullRequestChip(text: "draft", color: .secondary)
            } else if live?.mergeable == .conflicting {
                PullRequestChip(text: "conflicts", color: PullRequestStyle.failing)
            } else if let review = live.flatMap({ PullRequestStyle.review($0.reviewDecision) }) {
                Text(review.text.lowercased())
                    .font(.scopeCaption)
                    .foregroundStyle(review.color)
                    .lineLimit(1)
            }
        }
    }

    private static func age(_ date: Date) -> String {
        PullRequestFreshness.age(since: date, now: .now)
    }
}
