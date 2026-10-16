import AppKit
import SwiftUI
import ScopeAssist
import ScopeCore
import ScopeTasks

/// The band at the top of the inspector, level with the window toolbar: what the column is about. A task's name and
/// scope, with copy / open in editor / reveal on hover; without a task, the repository the Base sections show.
///
/// The rest of what used to sit in the task's summary band — the version strip, the prompt, the repo rows, the pull
/// request chip — moved into the Task and Pull Request sections, whose closed headers keep the essential.
struct InspectorSubjectBand: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

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
                HStack(spacing: 2) {
                    // The name is how the task is referred to in a prompt; ⌥ gives the slug `scope --task` takes.
                    CopyButton(label: "Copy task name") {
                        NSEvent.modifierFlags.contains(.option) ? task.record.slug : task.name
                    }
                    .help("Copy the task name — ⌥-click copies the slug “\(task.record.slug)”")
                    Button {
                        model.openTaskInEditor(task)
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Open Task in Editor (⇧⌘E)")
                    .accessibilityLabel("Open \(task.name) in Editor")
                    Button {
                        Reveal.inFinder(task.record.rootURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(task.name) in Finder")
                }
                .buttonStyle(.icon)
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .opacity(hovering ? 1 : 0)
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
                Text("No task selected")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            } else {
                Text("Nothing selected")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Surface.panel)
        .onHover { hovering = $0 }
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

/// The Task section: closed, the branch and where it stands (commits ahead, base moved on); open, the version strip,
/// the prompt the task was opened with and one row per repository with its sandbox state and `+N −M`.
struct TaskSection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .task, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { TaskVersionSummary(task: task) }
        } actions: {
            EmptyView()
        } content: {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    TaskBriefExcerpt(task: task)
                    TaskVersionStrip(task: task)
                    ForEach(task.activeRepos) { repo in
                        TaskRepoRow(task: task, repo: repo)
                    }
                    TaskServersRow(task: task)
                    TaskTimelineView(task: task)
                        .padding(.top, 8)
                        .usageID("timeline", label: "Task timeline")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    static let pullRequestRefreshInterval: Duration = .seconds(60)
}

/// The servers the task is running and what its sandboxes weigh, under the repository rows: the port chips
/// (`AppModel+Ports`) and the disk caption (`AppModel+DiskUsage`). Nothing is drawn until one of them has something.
private struct TaskServersRow: View {
    let task: TaskState

    var body: some View {
        if !task.listeningPorts.isEmpty || task.diskUsage != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TaskPortChips(task: task)
                Spacer(minLength: 0)
                TaskDiskCaption(task: task)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 4)
            .usageID("task-servers", label: "Task servers and disk")
        }
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

/// The closed Task header: the branch, `↑N`, and the base lag in warning colour when there is one.
private struct TaskVersionSummary: View {
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
                    .help("The base gained \(behind) \(behind == 1 ? "commit" : "commits") since the task forked; see Delta ▸ Base vs origin")
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
                .foregroundStyle(Ink.secondary)
                .help("Open in Editor (⌥-click copies the path)")
                .accessibilityLabel("Open \(repoName) in Editor")
                Button {
                    model.showInspector(.delta)
                    model.showDiff(model.delta.orderedFiles.first { $0.repo == repo.repoRelativePath })
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.iconTight)
                .foregroundStyle(Ink.secondary)
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
                Text("+\(additions)").foregroundStyle(isOnAccent ? Ink.onAccent : Self.added)
            }
            if deletions > 0 {
                Text("−\(deletions)").foregroundStyle(isOnAccent ? Ink.onAccent : Self.removed)
            }
        }
        .font(.system(size: size, design: .monospaced))
    }
}
