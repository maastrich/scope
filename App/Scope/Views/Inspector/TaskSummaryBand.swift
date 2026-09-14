import AppKit
import SwiftUI
import ScopeTasks

/// The band under the inspector's tab row while a task is selected: the task's name and scope, the version strip
/// (its branch, the base it forked from and where the two stand), the bound pull request, the prompt it was opened
/// with, and one row per repo with the sandbox state, `+N −M` and the Open in Editor / See Delta buttons.
///
/// This is the single owner of all of it. The same fields used to be drawn inside the sidebar, in a block injected
/// into the `List` under the selected task row, which shoved every row below it by a variable amount on every
/// click; the branch was drawn a second time by `DeltaView`. The sidebar now says *which* task, in one 28 pt row
/// like any other, and the panel says *what*. The checks of the pull request have the Pull Request tab to
/// themselves; the band keeps the one-line chip.
struct TaskSummaryBand: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The name is how the task is referred to in a prompt; ⌥ gives the slug `scope --task` takes.
                CopyButton(label: "Copy task name") {
                    NSEvent.modifierFlags.contains(.option) ? task.record.slug : task.name
                }
                .help("Copy the task name — ⌥-click copies the slug “\(task.record.slug)”")
                Text(model.scope(task.scopeID)?.name ?? task.record.scopeName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    model.openTaskInEditor(task)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.icon)
                .foregroundStyle(.secondary)
                .disabled(model.config.preferences.editor == nil)
                .help("Open Task in Editor (⇧⌘E)")
                .accessibilityLabel("Open \(task.name) in Editor")
                Button {
                    Reveal.inFinder(task.record.rootURL)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.icon)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(task.name) in Finder")
            }
            .frame(height: 22)

            TaskVersionStrip(task: task)

            if let pr = task.record.pullRequest {
                HStack(spacing: 6) {
                    Button {
                        model.openOnGitHub(pr.url)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(PullRequestStyle.color(model.liveChecks(for: task) ?? .none))
                                .frame(width: 6, height: 6)
                            Text("\(pr.label) \(pr.title)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    // A real URL link, which is what the pointing hand means on macOS.
                    .cursor(.pointingHand)
                    .help("Open on GitHub — \(pr.url.absoluteString)")
                    .accessibilityLabel("Open pull request \(pr.label) on GitHub")
                    Spacer(minLength: 4)
                    if let checks = model.liveChecks(for: task), checks != .none {
                        Text("\(PullRequestStyle.glyph(checks)) \(TaskPullRequestView.caption(checks))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PullRequestStyle.color(checks))
                    }
                }
                .frame(height: 22)
            }

            if let prompt = task.record.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .help(prompt)
            }

            ForEach(task.activeRepos) { repo in
                TaskRepoRow(task: task, repo: repo)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("PanelBackground"))
        // On the band, which is up under every tab: this is what notices the PR a thread opened and binds it, and
        // what keeps the checks fresh for the Pull Request tab.
        .task(id: task.id) {
            while !Task.isCancelled {
                await model.refreshTaskPullRequest(task)
                try? await Task.sleep(for: Self.pullRequestRefreshInterval)
            }
        }
    }

    static let pullRequestRefreshInterval: Duration = .seconds(60)
}

/// Where the task stands, in one tinted row: its branch, the base branch it forked from, the fork commit, how many
/// commits it has made since, and — the part that is easy to miss otherwise — whether the base has moved on
/// underneath it. Every number is `RepoDeltaSummary`'s, refreshed with the sidebar counts. A task on several
/// repositories reads the first summarised one for the base and commit, and sums the rest.
struct TaskVersionStrip: View {
    let task: TaskState

    var body: some View {
        let summaries = task.activeRepos.compactMap { task.summary(for: $0) }
        let lead = summaries.first { $0.mergeBase != nil } ?? summaries.first
        let ahead = summaries.reduce(0) { $0 + $1.ahead }
        let behind = summaries.map(\.behind).max() ?? 0
        HStack(spacing: 6) {
            Text(task.branch)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(task.branch)
            if let base = lead?.upstreamBranch {
                Text("from")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(base)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    .help("The task branch is measured against \(lead?.upstream ?? base)")
            }
            if let sha = lead?.mergeBase {
                Text("@")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(String(sha.prefix(7)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Merge-base: the base as it was when the task forked — \(sha)")
            }
            Spacer(minLength: 4)
            if ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(ahead) \(ahead == 1 ? "commit" : "commits") on the task branch since the base")
            }
            if behind > 0 {
                Text("base behind \(behind)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color("WarningText"))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color("WarningText").opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .help("The base gained \(behind) \(behind == 1 ? "commit" : "commits") since the task forked; see Delta ▸ Base vs origin")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One repo of the task: name, sandbox state, `+N −M`, a state dot, and (on hover) Open in Editor / See Delta.
private struct TaskRepoRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(repoName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Always in the hierarchy (keyboard focus and VoiceOver reach them); revealed on hover.
            HStack(spacing: 8) {
                Button {
                    model.openInEditorOrCopy(path: repo.sandboxPath)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(.secondary)
                .help("Open in Editor (⌥-click copies the path)")
                .accessibilityLabel("Open \(repoName) in Editor")
                Button {
                    model.inspectorTab = .delta
                    model.delta.selectedFile = model.delta.orderedFiles.first { $0.repo == repo.repoRelativePath }
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(.secondary)
                .help("See Delta (⌘D)")
                .accessibilityLabel("See Delta of \(repoName)")
            }
            .opacity(hovering ? 1 : 0)
            Text(stateCaption)
                .font(.system(size: 10.5))
                .foregroundStyle(stateIsWarning ? AnyShapeStyle(Color("WarningText")) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            DeltaCounts(additions: summary?.additions ?? 0, deletions: summary?.deletions ?? 0)
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel(stateCaption)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(repo.sandboxPath)
    }

    private var summary: RepoDeltaSummary? { task.summary(for: repo) }

    private var repoName: String { repo.isScopeRoot ? task.record.scopeName : repo.name }

    private var stateCaption: String {
        switch summary?.sandbox {
        case .none: "…"
        case .clean: "clean"
        case .dirty(let count): "\(count) uncommitted"
        case .missing: "missing"
        }
    }

    private var stateIsWarning: Bool {
        switch summary?.sandbox {
        case .dirty, .missing: true
        default: false
        }
    }

    private var dotColor: Color {
        switch summary?.sandbox {
        case .dirty: ThreadStateStyle.waiting
        case .missing: Color(nsColor: .systemRed)
        case .clean: ThreadStateStyle.done
        case .none: ThreadStateStyle.idle
        }
    }
}

/// `+N` green / `−N` red, mono 11, zero values omitted (design §3).
struct DeltaCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11

    static let added = Color("DiffAddedSign")
    static let removed = Color("DiffRemovedSign")

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 {
                Text("+\(additions)").foregroundStyle(Self.added)
            }
            if deletions > 0 {
                Text("−\(deletions)").foregroundStyle(Self.removed)
            }
        }
        .font(.system(size: size, design: .monospaced))
    }
}
