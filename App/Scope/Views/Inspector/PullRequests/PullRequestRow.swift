import SwiftUI
import ScopeGit

/// One open pull request: number + title (2 lines), author, `head → base`, the Draft / review / checks chips,
/// the relative update time, and "Open in Scope" (new task on the PR head) or "Switch" (task already bound).
struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let repo: RepoState
    let scope: ScopeState
    @State private var hovering = false

    private var boundTask: TaskState? { model.task(forPullRequest: pr.number, repo: repo, in: scope.id) }
    private var isOpening: Bool { model.pullRequests.openingNumber == pr.number }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Ink.secondary)
                    Text(pr.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    Text(pr.author)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Text(verbatim: "\(pr.headRefName) → \(pr.baseRefName)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pr.isCrossRepository, let owner = pr.headOwner {
                        Text("fork · \(owner)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    if pr.isDraft {
                        PullRequestChip(text: "Draft", color: .secondary)
                    }
                    if let review = PullRequestStyle.review(pr.reviewDecision) {
                        PullRequestChip(text: review.text, color: review.color)
                    }
                    if pr.checks != .none {
                        PullRequestChip(text: "\(PullRequestStyle.glyph(pr.checks)) checks", color: PullRequestStyle.color(pr.checks))
                    }
                    if pr.mergeable == .conflicting {
                        PullRequestChip(text: "Conflicts", color: PullRequestStyle.failing)
                    }
                    Spacer(minLength: 0)
                    Text(pr.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                if isOpening {
                    ScopeSpinner(size: 14)
                } else if let task = boundTask {
                    Button("Switch") { model.switchToTask(task) }
                        .help("Select the task \(task.name)")
                } else {
                    Button("Open in Scope") {
                        Task { await model.openPullRequest(pr, repo: repo, in: scope) }
                    }
                    .disabled(model.pullRequests.openingNumber != nil || scope.kind == .missing)
                    .help(openHelp)
                }
                Button {
                    model.openOnGitHub(pr.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(Ink.secondary)
                .cursor(.pointingHand)
                .help(pr.url.absoluteString)
                .opacity(hovering ? 1 : 0.55)
            }
            .buttonStyle(.scopeSecondary)
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 12))
        .background(hovering ? Fill.hover : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if let task = boundTask {
                Button("Switch to Task") { model.switchToTask(task) }
            } else {
                Button("Open in Scope") { Task { await model.openPullRequest(pr, repo: repo, in: scope) } }
            }
            Button("Open on GitHub") { model.openOnGitHub(pr.url) }
            Button("Copy URL") { Pasteboard.copy(pr.url.absoluteString) }
        }
    }

    private var openHelp: String {
        pr.isCrossRepository
            ? "Task on pull/\(pr.number)/head as local branch pr/\(pr.number) (fork: pushes need the fork's remote)"
            : "Task on \(pr.headRefName), tracking origin/\(pr.headRefName)"
    }
}

/// Small tinted capsule: `Draft`, `Approved`, `✓ checks`…
struct PullRequestChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
            .fixedSize()
    }
}
