import SwiftUI
import ScopeCore
import ScopeTasks

/// The Artifacts card: what the task produced. Closed, what was kept at archive and how many checkpoints; open,
/// the deliverable kept when the task was archived (REPORT.md, the files it was created for) with *Read*, then the
/// checkpoints. Files written outside the diff and the pages the agent published come in a later step
/// (`TaskArtifacts`); until then the card says so when there is nothing yet.
struct ArtifactsCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .artifacts, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } actions: {
            if let task {
                Button {
                    Reveal.inFinder(task.record.rootURL)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal the task folder in Finder")
                .accessibilityLabel("Reveal the task folder of \(task.name)")
            }
        } content: {
            if let task { content(task) }
        }
    }

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        let parts = summaryParts(task)
        if parts.isEmpty {
            Text("nothing yet").foregroundStyle(Ink.tertiary)
        } else {
            Text(parts.joined(separator: " · "))
        }
    }

    private func summaryParts(_ task: TaskState) -> [String] {
        var parts: [String] = []
        if let kept = model.deliverable(of: task), let first = kept.files.first {
            parts.append(kept.files.count == 1 ? first.name : "\(kept.files.count) files kept")
        }
        let count = task.checkpoints.count
        if count > 0 { parts.append("\(count) \(count == 1 ? "checkpoint" : "checkpoints")") }
        return parts
    }

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        let kept = model.deliverable(of: task)
        if kept == nil, task.checkpoints.isEmpty {
            CardEmptyState(title: "Nothing produced yet",
                           detail: "The report, the files written outside the diff and the checkpoints appear here.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let kept {
                    CardGroupLabel("Report")
                    KeptDeliverableRow(task: task, kept: kept)
                }
                TaskCheckpointsList(task: task)
                    .usageID("task-checkpoints", label: "Task checkpoints")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// One line for what the archive kept: the file, *deliverable*, and *Read* on the right.
private struct KeptDeliverableRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let kept: TaskDeliverable

    var body: some View {
        HStack(spacing: 8) {
            CardRowGlyph("doc.text")
            Text(kept.files.first?.name ?? "last answers")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("· deliverable")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
            Spacer(minLength: 0)
            Button("Read") { model.readDeliverable(of: task) }
                .buttonStyle(.plain)
                .font(.scopeCaption)
                .foregroundStyle(Color.accentColor)
                .help(TaskBriefExcerpt.keptHelp(kept))
                .usageID("inspector.artifacts.read-deliverable", label: "Read the deliverable")
        }
        .frame(height: 26)
    }
}

/// The centred two lines a card shows while it has nothing: what is missing, and what will fill it.
struct CardEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.scopeBody)
                .foregroundStyle(Ink.primary)
            Text(detail)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }
}

/// The task's checkpoints, newest first: when, which thread and turn, the reply's first words, `+N −M` against the
/// one before; on hover, Show diff / Restore files / Branch from here. Nothing asks: a restore checkpoints what it
/// replaces, so the list itself is the undo.
private struct TaskCheckpointsList: View {
    let task: TaskState
    @State private var showAll = false

    static let shortCount = 6

    var body: some View {
        let all = Array(task.checkpoints.reversed())
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardGroupLabel("Checkpoints", count: all.count)
                ForEach(showAll ? all : Array(all.prefix(Self.shortCount))) { checkpoint in
                    TaskCheckpointRow(task: task, checkpoint: checkpoint)
                }
                if all.count > Self.shortCount {
                    Button(showAll ? "Show fewer" : "Show all \(all.count)") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, 2)
                        .usageID("task.checkpoints-show-all", label: "Show every checkpoint")
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct TaskCheckpointRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let checkpoint: TaskCheckpoint
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(when)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(who)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let turn = checkpoint.turn {
                        Text("turn \(turn)")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                Text(checkpoint.headline)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Always in the hierarchy (keyboard focus and VoiceOver reach them); revealed on hover.
            HStack(spacing: 8) {
                Button {
                    Task { await model.readCheckpointDiff(checkpoint, of: task) }
                } label: {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: 12))
                }
                .help("Show diff — this checkpoint against the sandbox now, in the reading column")
                .accessibilityLabel("Show the diff of checkpoint \(checkpoint.number)")
                .usageID("task.checkpoint-diff", label: "Show a checkpoint's diff")
                Button {
                    Task { await model.restoreCheckpointFromUI(checkpoint, of: task) }
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                }
                .help("Restore files — the sandbox files as this checkpoint had them; the branch stays, and the files as they are now become a checkpoint first")
                .accessibilityLabel("Restore the files of checkpoint \(checkpoint.number)")
                .usageID("task.checkpoint-restore", label: "Restore a checkpoint's files")
                Button {
                    Task { await model.branchFromCheckpoint(checkpoint, of: task) }
                } label: {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 12))
                }
                .help("Branch from here — creates \(task.branch)-cp\(checkpoint.number) at this checkpoint, without checking it out")
                .accessibilityLabel("Branch from checkpoint \(checkpoint.number)")
                .usageID("task.checkpoint-branch", label: "Branch from a checkpoint")
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.secondary)
            .opacity(hovering ? 1 : 0)
            DeltaCounts(additions: checkpoint.additions, deletions: checkpoint.deletions)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var when: String {
        Calendar.current.isDateInToday(checkpoint.at)
            ? checkpoint.at.formatted(date: .omitted, time: .shortened)
            : checkpoint.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var who: String {
        switch checkpoint.reason {
        case .beforeRestore: "Before restore"
        case .beforeCopy: "Before copy"
        case .turn: checkpoint.threadTitle ?? "Thread"
        }
    }

    private var tooltip: String {
        var text = "Checkpoint \(checkpoint.number) · " + checkpoint.at.formatted(date: .abbreviated, time: .shortened)
        text += "\n" + checkpoint.repos.map { repo in
            let name = task.record.sandbox(key: repo.repoRelativePath)?.sandboxLabel(scopeName: task.record.scopeName)
                ?? (repo.repoRelativePath == "." ? task.record.scopeName : repo.repoRelativePath)
            return "\(name) @ \(repo.commit.prefix(7))" + (repo.skipped.isEmpty ? "" : " (left out: \(repo.skipped.joined(separator: ", ")))")
        }.joined(separator: "\n")
        return text
    }
}

