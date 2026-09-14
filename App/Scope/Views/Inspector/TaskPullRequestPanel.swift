import SwiftUI
import ScopeCore
import ScopeGit

/// The checks of the task's pull request, under its chip in the summary band. One summary row — `✓ n ✗ n ● n`
/// and a chevron — then the rows that matter: the failing checks alone while collapsed, every check (failures
/// first) once expanded. The list never grows past `visibleRows`: past that it scrolls on its own, so a PR with
/// fifty jobs leaves the prompt and the repo rows under it where they are.
///
/// A row is: state, name, a link to the check's page, and for a failed one **Send to Thread** — the end of its
/// log and a sentence naming it, pasted into the task's thread. The band that holds the panel drives the refresh.
struct TaskPullRequestPanel: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var expanded = false

    static let rowHeight: CGFloat = 20
    /// Rows shown before the list scrolls: enough to read a burst of failures, not enough to bury the band.
    static let visibleRows = 8

    var body: some View {
        let pr = model.pullRequests.taskPullRequests[task.id]
        VStack(alignment: .leading, spacing: 0) {
            if let pr {
                if pr.state != .open {
                    Label(pr.state == .merged ? "Merged" : "Closed", systemImage: pr.state == .merged ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.rowHeight)
                }
                if !pr.checkRuns.isEmpty {
                    summary(pr.checkRuns)
                    list(Self.shown(pr.checkRuns, expanded: expanded))
                }
            } else if let error = model.pullRequests.taskPullRequestErrors[task.id] {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color("WarningText"))
                    .lineLimit(2)
                    .help(error)
            }
        }
    }

    /// Failures first, then pending, passing, skipped; `gh`'s order within a group. Collapsed keeps the failures
    /// only — the rows with a button on them.
    static func shown(_ checks: [PullRequestCheck], expanded: Bool) -> [PullRequestCheck] {
        let sorted = checks.sorted { rank($0.state) < rank($1.state) }
        return expanded ? sorted : sorted.filter { $0.state == .failing }
    }

    private static func rank(_ state: PullRequestCheck.State) -> Int {
        switch state {
        case .failing: 0
        case .pending: 1
        case .passing: 2
        case .skipped: 3
        }
    }

    private func summary(_ checks: [PullRequestCheck]) -> some View {
        let counts = Dictionary(grouping: checks, by: \.state).mapValues(\.count)
        let hidden = checks.count - Self.shown(checks, expanded: false).count
        return Button {
            guard hidden > 0 else { return }
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ForEach([PullRequestCheck.State.failing, .pending, .passing, .skipped], id: \.self) { state in
                    if let count = counts[state], count > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: Self.symbol(state))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Self.color(state))
                            Text("\(count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("\(count) \(state.rawValue)")
                    }
                }
                Spacer(minLength: 4)
                // Nothing to unfold when every check fails: the chevron would toggle between identical lists.
                if hidden > 0 {
                    Text(expanded ? "Failures only" : "All \(checks.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show the failing checks only" : "Show every check")
        .accessibilityLabel(expanded ? "Show the failing checks only" : "Show all \(checks.count) checks")
    }

    @ViewBuilder private func list(_ checks: [PullRequestCheck]) -> some View {
        if !checks.isEmpty {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checks) { check in
                        row(check)
                    }
                }
            }
            .frame(height: CGFloat(min(checks.count, Self.visibleRows)) * Self.rowHeight)
        }
    }

    private func row(_ check: PullRequestCheck) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(check.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.color(check.state))
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
        .frame(height: Self.rowHeight)
    }

    private static func symbol(_ state: PullRequestCheck.State) -> String {
        switch state {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .skipped: "minus.circle"
        }
    }

    private static func color(_ state: PullRequestCheck.State) -> AnyShapeStyle {
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
