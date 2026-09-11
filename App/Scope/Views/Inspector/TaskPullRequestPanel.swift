import SwiftUI
import ScopeCore
import ScopeGit

/// The checks of the task's pull request, under its chip in the summary band: state, name, a link to the check's
/// page, and for a failed one **Send to Thread** — the end of its log and a sentence naming it, pasted into the
/// task's thread. Refreshed when the band shows and every minute while it does.
struct TaskPullRequestPanel: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    static let refreshInterval: Duration = .seconds(60)

    var body: some View {
        let pr = model.pullRequests.taskPullRequests[task.id]
        VStack(alignment: .leading, spacing: 0) {
            if let pr {
                if pr.state != .open {
                    Label(pr.state == .merged ? "Merged" : "Closed", systemImage: pr.state == .merged ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                }
                ForEach(pr.checkRuns) { check in
                    row(check)
                }
            } else if let error = model.pullRequests.taskPullRequestErrors[task.id] {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color("WarningText"))
                    .lineLimit(2)
                    .help(error)
            }
        }
        .task(id: task.id) {
            while !Task.isCancelled {
                await model.refreshTaskPullRequest(task)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func row(_ check: PullRequestCheck) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(check.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(check.state))
                .frame(width: 12)
                .accessibilityLabel(check.state.rawValue)
            Text(check.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if check.state == .failing {
                ThreadPicker(task: task, title: "Send the failure to the thread", systemImage: "paperplane") { thread in
                    Task { await model.sendCheckFailure(check, of: task, to: thread) }
                }
            }
            if let url = check.detailsURL {
                Button {
                    model.openOnGitHub(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
                .accessibilityLabel("Open \(check.title)")
            }
        }
        .frame(height: 20)
    }

    private func symbol(_ state: PullRequestCheck.State) -> String {
        switch state {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ state: PullRequestCheck.State) -> AnyShapeStyle {
        switch state {
        case .passing: AnyShapeStyle(PullRequestStyle.passing)
        case .failing: AnyShapeStyle(PullRequestStyle.failing)
        case .pending: AnyShapeStyle(PullRequestStyle.pending)
        case .skipped: AnyShapeStyle(.tertiary)
        }
    }
}

/// A button that acts on one of the task's running threads: the only one directly, a menu to pick from when there
/// are several, disabled when there is none.
struct ThreadPicker: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let title: String
    let systemImage: String
    var showsTitle = false
    let action: (ThreadID) -> Void

    var body: some View {
        let live = model.threads(in: task.id).filter(\.isAlive)
        if live.count > 1 {
            Menu {
                ForEach(live) { session in
                    Button(model.displayTitle(for: session)) { action(session.id) }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(showsTitle ? .visible : .hidden)
            .fixedSize()
            .help(title)
        } else {
            Button {
                if let only = live.first { action(only.id) }
            } label: {
                label
            }
            .buttonStyle(.iconTight)
            .disabled(live.isEmpty)
            .help(live.isEmpty ? "\(title) — no thread of this task is running" : title)
        }
    }

    @ViewBuilder private var label: some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .accessibilityLabel(title)
        }
    }
}
