import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// The Context card: what the agent was given and how the task has gone. Closed, the model of the task's thread
/// and how full its context window is (or how long the brief is); open, the brief folded to four lines with
/// *Read in full* and the topic, the mission checklist when the task is one, what the agent reads — the context
/// files where its threads start and the skills its sandboxes hold — the model with its context gauge and tokens,
/// and the task's timeline: agent time, time waiting for you, elapsed time, one lane per thread.
struct ContextCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .context, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } actions: {
            if let task, !(task.record.prompt ?? "").isEmpty {
                Button {
                    model.readBrief(of: task)
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Read the brief in full, in the reading column")
                .accessibilityLabel("Read the brief of \(task.name)")
            }
        } content: {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    CardGroupLabel("Brief")
                    TaskBriefExcerpt(task: task)
                    if let mission = task.record.mission {
                        MissionChecklist(task: task, mission: mission)
                    }
                    CardGroupLabel("Given to the agent")
                        .padding(.top, 4)
                    GivenToAgentRows(task: task)
                    if let thread = modelThread(of: task) {
                        CardGroupLabel("Model")
                            .padding(.top, 4)
                        ModelRow(task: task, thread: thread)
                    }
                    CardGroupLabel("Timeline · since creation")
                        .padding(.top, 4)
                    TaskTimelineView(task: task)
                        .padding(.top, 4)
                        .usageID("timeline", label: "Task timeline")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    /// The thread whose model the card shows: the selected one when it belongs to the task, else the first thread
    /// of the task that was opened with a model or reported one. `nil` for a task of shells alone.
    private func modelThread(of task: TaskState) -> ThreadSession? {
        func hasModel(_ session: ThreadSession) -> Bool {
            session.record.model != nil || session.contextWindow?.modelName != nil || session.contextWindow?.modelID != nil
        }
        if let current = model.currentThread, current.record.taskID == task.id.rawValue, hasModel(current) { return current }
        return model.threads(in: task.id).first(where: hasModel)
    }

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        if let thread = modelThread(of: task), let name = Self.modelName(thread) {
            Text(thread.contextWindow?.percentageText.map { "\(name) · \($0)" } ?? name)
                .monospacedDigit()
        } else {
            let lines = (task.record.prompt ?? "").split(whereSeparator: \.isNewline).count
            Text(lines == 0 ? "no brief" : "brief · \(lines) \(lines == 1 ? "line" : "lines")")
                .foregroundStyle(Ink.tertiary)
        }
    }

    /// `Fable 5.1`: the driver's own name for the model when it reported one, else the id made readable.
    static func modelName(_ thread: ThreadSession) -> String? {
        ModelLabel.line(model: thread.record.model ?? thread.contextWindow?.modelID, reportedName: thread.contextWindow?.modelName,
                        driver: nil, driverVersion: nil)
    }
}

/// One line per context file the agent reads — Scope's own, then the repository's — each opening in the reading
/// column, and the skills the sandboxes hold as chips. Read from disk when the card appears and whenever the task's
/// sandboxes change (`changeTick`): an agent can rewrite its `CLAUDE.md` mid-task.
private struct GivenToAgentRows: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var files: [TaskContextFiles.Entry] = []
    @State private var skills: [String] = []
    @State private var memories: [MemoryFolder] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if files.isEmpty {
                Text("no context file where the threads start")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.vertical, 4)
            }
            ForEach(files) { file in
                ContextFileRow(file: file, scopeName: model.scope(task.scopeID)?.name ?? task.record.scopeName) {
                    model.readContextFile(file, of: task)
                }
            }
            if !skills.isEmpty {
                HStack(spacing: 8) {
                    CardRowGlyph("square.grid.2x2")
                    Text("Skills loaded")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(skills.count)")
                        .font(.scopeValue)
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.vertical, 4)
                .help("The skills in the sandboxes' .claude/skills: copied from the base checkout at setup, or committed")
                FlowRow(spacing: 4) {
                    ForEach(skills, id: \.self) { skill in
                        ContextChip(text: skill)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 4)
                .accessibilityLabel("Skills: \(skills.joined(separator: ", "))")
            }
            ForEach(memories) { memory in
                MemoryRow(memory: memory)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: task.id) { reload() }
        .onChange(of: task.changeTick) { reload() }
    }

    private func reload() {
        files = model.contextFiles(of: task)
        skills = model.skills(of: task)
        let record = task.record
        Task {
            let placements = await model.claudeMemoryPlacements(of: record)
            memories = placements.enumerated().map { index, placement in
                MemoryFolder(placement: placement, isOwn: index == 0,
                             notes: (try? FileManager.default.contentsOfDirectory(atPath: placement.directory.path(percentEncoded: false)))?
                                .filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }.count ?? 0)
            }
        }
    }
}

/// A Claude Code memory folder of the task (`ClaudeMemory`): the one its threads write to first, then the ones
/// they may read.
private struct MemoryFolder: Identifiable {
    let placement: ClaudeMemory.Placement
    let isOwn: Bool
    let notes: Int
    var id: String { placement.directory.path }
}

/// `Memory front · threads write here    12 notes`; a click shows the folder in the Finder.
private struct MemoryRow: View {
    let memory: MemoryFolder
    @State private var hovering = false

    var body: some View {
        Button {
            let url = memory.placement.directory
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            HStack(spacing: 8) {
                CardRowGlyph("brain")
                Text("Memory \(memory.placement.label)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(memory.isOwn ? "· threads write here" : "· readable")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(memory.notes == 1 ? "1 note" : "\(memory.notes) notes")
                    .font(.scopeValue)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .cursor(.pointingHand)
        .help("Claude Code auto memory: \(memory.placement.directory.path(percentEncoded: false)) — show it in the Finder")
        .accessibilityLabel("Memory \(memory.placement.label), \(memory.isOwn ? "threads write here" : "readable"), \(memory.notes) notes")
        .usageID("inspector.context.memory", label: "Show a Claude memory folder")
    }
}

/// `CLAUDE.local.md · task context, written by Scope    1.8 kB`: the file by name, where it comes from, and its
/// weight; a click reads it.
private struct ContextFileRow: View {
    let file: TaskContextFiles.Entry
    let scopeName: String
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CardRowGlyph("doc.text")
                Text(file.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(origin)")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(TaskContextFiles.sizeText(file.size))
                    .font(.scopeValue)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .cursor(.pointingHand)
        .help("\(file.url.path) — read it in the reading column")
        .accessibilityLabel("\(file.name), \(origin), \(TaskContextFiles.sizeText(file.size))")
        .usageID("inspector.context.file", label: "Read a context file")
    }

    private var origin: String {
        var text = switch file.origin {
        case .writtenByScope: "written by Scope"
        case .repository: "repository's own"
        }
        if let sandbox = file.sandbox { text += " · \(sandbox)" }
        return text
    }
}

/// The model line: `Fable 5.1 · Claude Code 2.1.47`, the context gauge with its percentage when the driver reported
/// one, and under it what the task's threads consumed from the token ledger.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let thread: ThreadSession

    var body: some View {
        let report = thread.contextWindow
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                CardRowGlyph("cpu")
                (Text(ContextCard.modelName(thread) ?? thread.profile.name)
                    .font(.system(size: 12, weight: .semibold))
                 + Text(driverSuffix(report))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let fraction = report?.fraction, let text = report?.percentageText {
                    ContextGauge(fraction: fraction)
                        .frame(maxWidth: 80)
                    Text(text)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize()
                }
            }
            .padding(.vertical, 4)
            .help(gaugeHelp(report))
            if let caption {
                Text(caption)
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 24)
                    .padding(.bottom, 4)
                    .help("What the task's threads consumed, read from their Claude Code transcripts: everything the model read, what it wrote, and the share read from the prompt cache")
            }
        }
        .usageID("inspector.context.model", label: "Model and context")
    }

    /// ` · Claude Code 2.1.47`, ` · Claude Code`: the driver, with its version once it said. A profile's variant
    /// in parentheses (`Claude Code (bypass)`) is left out: the line is about the tool, and the room is short.
    private func driverSuffix(_ report: ContextWindowReport?) -> String {
        guard ContextCard.modelName(thread) != nil else { return "" }
        let driver = thread.profile.name.split(separator: "(").first?.trimmingCharacters(in: .whitespaces) ?? thread.profile.name
        return " · " + (report?.driverVersion.map { "\(driver) \($0)" } ?? driver)
    }

    private func gaugeHelp(_ report: ContextWindowReport?) -> String {
        guard let report, let text = report.percentageText else {
            return "The driver has not reported how full its context window is."
        }
        var help = "Context window \(text) full"
        if let size = report.windowSize { help += " of \(TokenUsageText.compact(size)) tokens" }
        return help + ", as the driver last reported \(report.reportedAt.formatted(.relative(presentation: .named)))"
    }

    private var caption: String? {
        guard let row = model.tokenUsage.snapshot.tasks[task.record.id.rawValue] else { return nil }
        return TokenUsageText.contextCaption(row.total)
    }
}

/// A thin bar of `Color.accentColor` over `Fill.quiet`: how full the context window is. The fill moves with the
/// figure unless Reduce Motion is on.
struct ContextGauge: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * min(1, max(0, fraction)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        }
        .frame(height: 4)
        .background(Fill.quiet, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Context window")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent full")
    }
}

/// A quiet 18 pt chip for a word: a skill, a topic.
struct ContextChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// The small uppercase label that heads a group of rows inside a card (*Brief*, *Checkpoints*).
struct CardGroupLabel: View {
    let text: String
    var count: Int? = nil

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.scopeMicro)
                .tracking(0.4)
                .foregroundStyle(Ink.tertiary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
