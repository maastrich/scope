import AppKit
import SwiftUI
import ScopeAssist
import ScopeCore
import ScopeTasks

/// The band at the top of the inspector, level with the window toolbar: what the column is about, and the pane
/// strip. A task's name and scope; without a task, the repository the Repository cards show.
///
/// Copy / open in editor / reveal moved to the Environment card's header, the version strip, the prompt, the repo
/// rows and the pull request chip into the cards, whose closed headers keep the essential.
struct InspectorSubjectBand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let task = model.currentTask {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                Text(task.name)
                    .font(.scopeTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.name)
                Text(model.scope(task.scopeID)?.name ?? task.record.scopeName)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                TaskTokenBadge(task: task)
                if let hint = task.archiveHint {
                    ArchiveHintChip(task: task, hint: hint)
                }
                Spacer(minLength: 4)
                InspectorPaneStrip()
            } else if let repo = model.baseRepo {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                Text(repo.shortName)
                    .font(.scopeTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(repo.url.path)
                Text("repository")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 4)
                InspectorPaneStrip()
            } else {
                Text("Nothing selected")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Surface.panel)
    }
}

/// "Looks finished — archive?": the assistant's reading of the last reply (spec §4.10), as a proposal with its two
/// answers. The hint goes with the next turn in the task, with the archive, or with the ✕.
private struct ArchiveHintChip: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let hint: ArchiveHint

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await model.archiveTask(task.id) }
            } label: {
                Label("Looks finished — archive?", systemImage: "archivebox")
                    .font(.scopeCaption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .help(hint.reason.isEmpty ? "The assistant reads the last reply as a final deliverable." : hint.reason)
            .usageID("inspector.task.assist-archive", label: "Archive from the assistant's hint")
            Button {
                model.dismissArchiveHint(task)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.tertiary)
            .help("Not finished")
            .accessibilityLabel("Dismiss the archive hint")
            .usageID("inspector.task.assist-archive-dismiss", label: "Dismiss the archive hint")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Surface.ground, in: Capsule())
    }
}

/// What every task-wide number reads: the first summarised repository for the base and fork commit, the sum of the
/// commits made, the largest lag of a base.
@MainActor
struct TaskVersionFacts {
    let lead: RepoDeltaSummary?
    let ahead: Int
    let behind: Int

    init(task: TaskState) {
        let summaries = task.activeRepos.compactMap { task.summary(for: $0) }
        lead = summaries.first { $0.mergeBase != nil } ?? summaries.first
        ahead = summaries.reduce(0) { $0 + $1.ahead }
        behind = summaries.map(\.behind).max() ?? 0
    }
}

/// The closed Environment header: the branch, `↑N`, the base lag in warning colour when there is one, and a setup
/// still running or failed.
struct TaskVersionSummary: View {
    let task: TaskState

    var body: some View {
        let facts = TaskVersionFacts(task: task)
        HStack(spacing: 6) {
            Text(task.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .truncationMode(.middle)
            if facts.ahead > 0 {
                Text("↑\(facts.ahead)")
                    .font(.scopeValue)
                    .fixedSize()
            }
            if facts.behind > 0 {
                Text("base behind \(facts.behind)")
                    .foregroundStyle(Color("WarningText"))
                    .fixedSize()
            }
            switch task.record.setupState {
            case .running:
                Text("· setup running")
                    .foregroundStyle(ThreadStateStyle.running)
                    .fixedSize()
            case .failed:
                Text("· setup failed")
                    .foregroundStyle(PullRequestStyle.failing)
                    .fixedSize()
            case .notRun, .succeeded, .skipped:
                EmptyView()
            }
        }
    }
}

/// Where the task stands, in one tinted row: its branch, the base branch it forked from, the fork commit, how many
/// commits it has made since, and — the part that is easy to miss otherwise — whether the base has moved on
/// underneath it. Every number is `RepoDeltaSummary`'s, refreshed with the sidebar counts. A task on several
/// repositories reads the first summarised one for the base and commit, and sums the rest.
struct TaskVersionStrip: View {
    let task: TaskState

    var body: some View {
        let facts = TaskVersionFacts(task: task)
        let lead = facts.lead
        let ahead = facts.ahead
        let behind = facts.behind
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
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Text(base)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Fill.quiet, in: RoundedRectangle(cornerRadius: 4))
                    .help("The task branch is measured against \(lead?.upstream ?? base)")
            }
            if let sha = lead?.mergeBase {
                Text("@")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Text(String(sha.prefix(7)))
                    .font(.scopeValue)
                    .foregroundStyle(Ink.secondary)
                    .help("Merge-base: the base as it was when the task forked — \(sha)")
            }
            Spacer(minLength: 4)
            if ahead > 0 {
                Text("↑\(ahead)")
                    .font(.scopeValue)
                    .foregroundStyle(Ink.secondary)
                    .help("\(ahead) \(ahead == 1 ? "commit" : "commits") on the task branch since the base")
            }
            if behind > 0 {
                Text("base behind \(behind)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color("WarningText"))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color("WarningText").opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .help("The base gained \(behind) \(behind == 1 ? "commit" : "commits") since the task forked; see Changes ▸ Base vs origin")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One worktree of the task, one line of the Environment card: a box glyph, the repository, its branch when it is
/// not the task's own, the sandbox state, `+N −M`, a state dot, and (on hover) Open in Editor / See Changes — plus
/// New Thread and Remove on a branch added beside the primary sandbox.
struct TaskRepoRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            CardRowGlyph("shippingbox")
            Text(repoName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if repo.isSecondary {
                Text(repo.branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .help("A worktree of \(repoName) on \(repo.branch), beside the task's sandbox")
            }
            Spacer(minLength: 0)
            // Always in the hierarchy (keyboard focus and VoiceOver reach them); revealed on hover.
            HStack(spacing: 8) {
                if repo.isSecondary {
                    Button {
                        Task { _ = await model.newThread(in: task.scopeID, taskID: task.id, branch: repo.branch) }
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.iconTight)
                    .foregroundStyle(Ink.secondary)
                    .help("New Thread on \(repo.branch)")
                    .accessibilityLabel("New thread on \(repo.branch)")
                    .usageID("inspector.task.branch-thread", label: "New thread on a task branch")
                    Button {
                        model.removeBranchFromUI(repo, of: task)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.iconTight)
                    .foregroundStyle(Ink.secondary)
                    .help("Remove Branch — the worktree goes, uncommitted changes saved first; the branch stays")
                    .accessibilityLabel("Remove the worktree on \(repo.branch)")
                    .usageID("inspector.task.branch-remove", label: "Remove a branch from the task")
                }
                Button {
                    model.openInEditorOrCopy(path: repo.sandboxPath)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(Ink.secondary)
                .help("Open in Editor (⌥-click copies the path)")
                .accessibilityLabel("Open \(repoName) in Editor")
                Button {
                    model.showInspector(.delta)
                    model.showDiff(model.delta.orderedFiles.first { $0.repo == repo.sandboxKey })
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(Ink.secondary)
                .help("See Changes (⌘D)")
                .accessibilityLabel("See the changes of \(repoName)")
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
        .frame(height: 26)
        .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
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

/// The 16 pt monochrome glyph at the left of a card row: one per fact, as in the mockups.
struct CardRowGlyph: View {
    let systemImage: String

    init(_ systemImage: String) { self.systemImage = systemImage }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11.5))
            .foregroundStyle(Ink.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// `+N` green / `−N` red, mono 11, zero values omitted (design §3).
struct DeltaCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11
    @Environment(\.isOnAccent) private var isOnAccent

    static let added = Color("DiffAddedSign")
    static let removed = Color("DiffRemovedSign")

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 {
                Text(verbatim: "+\(String(additions))").foregroundStyle(isOnAccent ? Ink.onAccent : Self.added)
            }
            if deletions > 0 {
                Text(verbatim: "−\(String(deletions))").foregroundStyle(isOnAccent ? Ink.onAccent : Self.removed)
            }
        }
        .font(.system(size: size, design: .monospaced))
    }
}
