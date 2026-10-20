import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// The Artifacts card: what the task produced besides its diff (`TaskArtifacts`). Closed, one line — `REPORT.md ·
/// 3 files · 1 page`, else the checkpoints, else *nothing yet*. Open, four groups: the report with a preview of its
/// opening and *Read*; the files the threads wrote where git does not look, the newest image as a thumbnail; the pages
/// the agent published; the checkpoints. The card reads: nothing here copies, moves or deletes a file.
///
/// What it reads is loaded by `InspectorView`, not here: the card may sit on Details, unbuilt, and still has to say
/// whether it has something for Overview.
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
                    Task { await model.refreshArtifacts(of: task) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh — look again at the report, the files written and the pages published")
                .accessibilityLabel("Refresh the artifacts of \(task.name)")
                .usageID("inspector.artifacts.refresh", label: "Refresh the artifacts")
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
        let text = summaryText(task)
        Text(text).foregroundStyle(text == "nothing yet" ? Ink.tertiary : Ink.secondary)
    }

    /// `TaskArtifacts.summary`, with what the archive kept standing in for a report that is gone.
    private func summaryText(_ task: TaskState) -> String {
        let artifacts = task.artifacts ?? TaskArtifacts(checkpoints: task.checkpoints)
        guard artifacts.report == nil, let kept = model.deliverable(of: task), let first = kept.files.first else {
            return artifacts.summary
        }
        var parts = [kept.files.count == 1 ? first.name : "\(kept.files.count) files kept"]
        let rest = TaskArtifacts(files: artifacts.files, pages: artifacts.pages).summary
        if rest != "nothing yet" { parts.append(rest) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        let artifacts = task.artifacts ?? TaskArtifacts(checkpoints: task.checkpoints)
        let kept = artifacts.report == nil ? model.deliverable(of: task) : nil
        Group {
            if artifacts.isEmpty, kept == nil {
                CardEmptyState(title: "Nothing produced yet",
                               detail: "REPORT.md, files written outside the diff and published pages appear here.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let report = artifacts.report {
                        CardGroupLabel("Report")
                        ReportRow(task: task, report: report)
                        if let preview = task.reportPreview, !preview.blocks.isEmpty {
                            ReportPreview(document: preview)
                        }
                    } else if let kept {
                        CardGroupLabel("Report")
                        KeptDeliverableRow(task: task, kept: kept)
                    }
                    if !artifacts.files.isEmpty {
                        WrittenFilesGroup(task: task, artifacts: artifacts)
                    }
                    if !artifacts.pages.isEmpty {
                        PublishedGroup(pages: artifacts.pages)
                    }
                    TaskCheckpointsList(task: task)
                        .usageID("task-checkpoints", label: "Task checkpoints")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: Report

/// The report as it is on disk: its name, *deliverable* when the task declares it, its age and `+N` since the
/// last checkpoint when known, *Read* on the right.
private struct ReportRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let report: TaskArtifacts.Report

    var body: some View {
        HStack(spacing: 8) {
            CardRowGlyph("doc.text")
            Text(report.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if report.isDeclared {
                Text("· deliverable")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if let modifiedAt = report.modifiedAt {
                    Text(ArtifactAge.text(modifiedAt))
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
                if let additions = report.additions, additions > 0 {
                    Text("·").font(.scopeCaption).foregroundStyle(Ink.tertiary)
                    DeltaCounts(additions: additions, deletions: 0)
                }
            }
            .fixedSize()
            Button("Read") { model.readReport(of: task) }
                .buttonStyle(.plain)
                .font(.scopeCaption)
                .foregroundStyle(Color.accentColor)
                .help("Read \(report.name) in the reading column")
                .usageID("inspector.artifacts.read-report", label: "Read the report")
        }
        .frame(height: 26)
        .help(report.path)
    }
}

/// What the archive kept when the file itself is gone: the file, *deliverable*, and *Read* on the right.
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
            Text("· kept at archive")
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

/// The report's opening, rendered as Markdown in a bordered box on the ground: enough to know what it says without
/// opening it. Set smaller than the reading column (a card is 380 pt wide), cut at a height rather than a block so a
/// long first paragraph does not swallow the card.
private struct ReportPreview: View {
    let document: MarkdownDocument
    @State private var isCut = false

    static let maxHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Bool.self) { $0.size.height > Self.maxHeight } action: { isCut = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Self.maxHeight, alignment: .top)
        .clipped()
        // A cut line fades out rather than showing half its glyphs; a preview that fits is left as is.
        .mask {
            if isCut {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.78),
                                       .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Surface.ground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Surface.stroke, lineWidth: 1))
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityLabel("Preview of the report")
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(text, font: .system(size: level <= 2 ? 12 : 11.5, weight: .semibold))
                .foregroundStyle(Ink.primary)
        case .paragraph(let text):
            MarkdownInlineText(text, font: .scopeRow)
                .foregroundStyle(Ink.secondary)
        case .list(let list):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(list.items.prefix(5).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(list.ordered ? "\(list.start + index)." : "•")
                            .font(.scopeRow)
                            .foregroundStyle(Ink.tertiary)
                        MarkdownInlineText(item.blocks.first?.plainText ?? "", font: .scopeRow)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.leading, 4)
        case .code(_, let text), .raw(let text):
            Text(text)
                .font(.scopeValue)
                .foregroundStyle(Ink.secondary)
                .lineLimit(4)
        case .rule:
            Rectangle().fill(Surface.stroke).frame(height: 1)
        default:
            Text(block.plainText)
                .font(.scopeRow)
                .foregroundStyle(Ink.secondary)
                .lineLimit(4)
        }
    }
}

// MARK: Files written

/// *Files written this task · outside the repo diff*: the newest image as a thumbnail, then a row per file — its
/// path cut in the middle, the turn that wrote it, its size — dimmed with *gone* when it is no longer there.
private struct WrittenFilesGroup: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let artifacts: TaskArtifacts
    @State private var showAll = false

    static let shortCount = 6

    var body: some View {
        let files = artifacts.files
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Files written this task".uppercased())
                    .font(.scopeMicro)
                    .tracking(0.4)
                    .foregroundStyle(Ink.tertiary)
                Text("· outside the repo diff")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            if let image = artifacts.newestImage {
                ArtifactThumbnail(file: image) { model.openArtifactFile(image, of: task) }
            }
            ForEach(showAll ? files : Array(files.prefix(Self.shortCount))) { file in
                WrittenFileRow(file: file) { model.openArtifactFile(file, of: task) }
            }
            if files.count > Self.shortCount {
                Button(showAll ? "Show fewer" : "Show all \(files.count)") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .padding(.top, 2)
                    .usageID("task.artifacts-show-all-files", label: "Show every file written")
            }
        }
    }
}

private struct WrittenFileRow: View {
    let file: TaskArtifacts.WrittenFile
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CardRowGlyph(file.isImage ? "photo" : "doc")
                Text(file.name)
                    .font(.scopeRow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(file.exists ? Ink.primary : Ink.tertiary)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(hovering && file.exists ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.exists)
        .opacity(file.exists ? 1 : 0.6)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel(file.exists ? "Open \(file.name)" : "\(file.name), gone")
    }

    private var trailing: String {
        var parts = ["turn \(file.turn)"]
        if let facts = file.facts {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(facts.bytes), countStyle: .file))
        } else {
            parts.append("gone")
        }
        return parts.joined(separator: " · ")
    }

    private var tooltip: String {
        var lines = [file.path, "\(file.tool) · \(file.threadTitle) · turn \(file.turn)"]
        switch file.placement {
        case .outsideSandboxes: lines.append("Outside the task's worktrees: not in the diff.")
        case .ignored: lines.append("In a folder git ignores: not in the diff.")
        case .binary: lines.append("A binary: the diff cannot show it.")
        }
        if !file.exists { lines.append("The file is no longer there.") }
        return lines.joined(separator: "\n")
    }
}

/// The newest image still on disk, 84 pt high, its name and pixel size in the corner; a click opens it in the
/// viewer column. Decoded off the main actor; nothing shows until it is in, and a file that cannot be decoded
/// shows nothing at all.
private struct ArtifactThumbnail: View {
    let file: TaskArtifacts.WrittenFile
    let open: () -> Void
    @State private var decoded: DecodedImage?

    var body: some View {
        // A container even while empty: `.task` needs a view to attach to before the image is in.
        VStack(spacing: 0) {
            if let decoded {
                Button(action: open) {
                    ZStack(alignment: .bottomLeading) {
                        Image(nsImage: decoded.image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .frame(height: 84, alignment: .top)
                            .clipped()
                        Text("\((file.path as NSString).lastPathComponent) · \(decoded.dimensions)")
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Surface.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 3))
                            .padding(6)
                    }
                    .background(Checkerboard())
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Surface.stroke, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(file.name)")
                .accessibilityLabel("Thumbnail of \(file.name), \(decoded.dimensions)")
                .padding(.vertical, 4)
            }
        }
        .task(id: "\(file.path)|\(file.facts?.modifiedAt?.timeIntervalSince1970 ?? 0)") {
            let url = URL(fileURLWithPath: file.path)
            let image = await Task.detached(priority: .utility) { () -> DecodedImage? in
                guard let data = try? ImageFiles.read(at: url) else { return nil }
                return DecodedImage(data: data)
            }.value
            decoded = image
        }
    }
}

// MARK: Published

/// *Published*: a row per page the agent linked in its answers — its title or host, the host at the right, and a
/// link glyph; the whole row opens the browser.
private struct PublishedGroup: View {
    @Environment(AppModel.self) private var model
    let pages: [TaskArtifacts.Page]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardGroupLabel("Published")
            ForEach(pages) { page in
                PublishedRow(page: page) { model.openArtifactPage(page) }
            }
        }
        .padding(.top, 4)
    }
}

private struct PublishedRow: View {
    let page: TaskArtifacts.Page
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CardRowGlyph(page.systemImage)
                Text(page.title)
                    .font(.scopeRow)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 4)
                Text(page.host)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? Ink.primary : Ink.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(page.url)\nSaid by \(page.threadID.prefix(8)) at turn \(page.turn) — opens in the browser")
        .accessibilityLabel("Open \(page.title) in the browser")
    }
}

/// `6 min`, `3 h`, `2 d`: how long ago a file changed, in the fewest characters a row can afford.
enum ArtifactAge {
    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86400)) d"
    }
}

/// The centred two lines a card shows while it has nothing: what is missing, and what will fill it — the second on
/// Details only, so a card pinned to Overview stays short there.
struct CardEmptyState: View {
    let title: String
    let detail: String
    @Environment(\.inspectorPage) private var page

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.scopeBody)
                .foregroundStyle(page == .overview ? Ink.secondary : Ink.primary)
            if page == .details {
                Text(detail)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, page == .overview ? 10 : 18)
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

