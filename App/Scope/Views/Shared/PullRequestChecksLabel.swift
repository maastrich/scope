import SwiftUI
import ScopeGit
import ScopeTasks

/// `✓ checks passed · 4 min ago`: a pull request's checks and how old that reading is. Past
/// `PullRequestFreshness.staleAfterIntervals` background intervals the colour goes neutral — a green that old may no
/// longer be true. Redrawn every minute so the age moves on its own.
struct PullRequestChecksLabel: View {
    let checks: PullRequest.Checks
    let checkedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = PullRequestFreshness.isStale(checkedAt: checkedAt, now: context.date)
            HStack(spacing: 4) {
                Text("\(PullRequestStyle.glyph(checks)) \(caption)")
                    .foregroundStyle(stale ? PullRequestStyle.neutral : PullRequestStyle.color(checks))
                if let checkedAt {
                    Text("· \(PullRequestFreshness.age(since: checkedAt, now: context.date))")
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .help(checkedAt.map { "Read from GitHub \($0.formatted(date: .omitted, time: .shortened))" + (stale ? " — may be out of date" : "") }
                  ?? "Not read from GitHub since Scope opened")
        }
    }

    private var caption: String {
        switch checks {
        case .passing: "checks passed"
        case .failing: "checks failing"
        case .pending: "checks running"
        case .none: ""
        }
    }
}

/// `· read 4 min ago`, after the pull request's own "updated" date: when Scope last asked GitHub.
struct PullRequestReadAge: View {
    let checkedAt: Date?

    var body: some View {
        if let checkedAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("· read \(PullRequestFreshness.age(since: checkedAt, now: context.date))")
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// `idle 4d` or `PR closed` for a forgotten task (`TaskDormancy`); nothing otherwise. A detailed row puts it first
/// on its second line, ahead of what the agent last did — that line is days old, and this says so — followed by
/// ` · ` (`separated`); a compact row, which has no second line, at the end of the row.
struct TaskDormancyCaption: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    /// `· ` after the caption, when the agent's activity follows it on a second line.
    var separated = false
    /// ` · ` before the caption, when it follows the name on a one-line row.
    var leading = false

    var body: some View {
        if let caption = model.dormancy(of: task).caption {
            Text(leading ? " · \(caption)" : separated ? "\(caption) · " : caption)
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
