import AppKit
import SwiftUI
import ScopeCore
import ScopeTasks

/// The Environment card: where the task runs. Closed, the branch and where it stands (commits ahead, base moved
/// on, a setup running or failed); open, one fact per line — the version strip, a line per worktree with its
/// sandbox state and `+N −M`, the setup with its state as a chip (the log opens in the reading column), the ports of
/// the task's block something listens on with the processes behind them, and a foot line with the disk and the
/// agent time. Add Branch, Copy name, Open in Editor and Reveal come on hover.
struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .environment, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { TaskVersionSummary(task: task) }
        } actions: {
            if let task { actions(task) }
        } content: {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    if !task.record.trying.isEmpty {
                        TryBanner(task: task, sessions: task.record.trying, placement: "inspector.environment")
                            .padding(.bottom, 8)
                    }
                    TaskVersionStrip(task: task)
                    ForEach(task.activeSandboxes, id: \.sandboxKey) { repo in
                        TaskRepoRow(task: task, repo: repo)
                    }
                    TaskSetupRow(task: task)
                    TaskPortsRow(task: task)
                    TaskMachineRow(task: task)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                // After a relaunch nothing has resolved the commands yet: a setup that never ran still shows its line.
                .task(id: task.id) {
                    if task.setupCommands == nil { await model.loadSetupCommands(of: task) }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ task: TaskState) -> some View {
        if !task.isArchived {
            Button {
                model.addBranchFromUI(task)
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .help("Add Branch… — a second worktree of a repository of the task, on a branch of its own")
            .accessibilityLabel("Add a branch to \(task.name)")
            .usageID("inspector.environment.add-branch", label: "Add a branch to the task")
        }
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
}

/// The setup line: the command in mono, its state as a chip at the right — running with the seconds ticking, `✓`
/// or `✗` with how long it took. A click opens the log in the reading column. Nothing is drawn for a task whose
/// repositories declare no setup, and nothing ran.
private struct TaskSetupRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var hovering = false

    var body: some View {
        if let facts {
            Button {
                model.readSetupLog(of: task)
            } label: {
                HStack(spacing: 8) {
                    CardRowGlyph("gearshape")
                    Text("Setup")
                        .font(.system(size: 12, weight: .semibold))
                    if !facts.command.isEmpty {
                        Text(facts.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(facts.command)
                    }
                    Spacer(minLength: 4)
                    SetupStateChip(setup: task.record.setup)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -6)
            .onHover { hovering = $0 }
            .help("Open the setup log in the reading column")
            .accessibilityLabel("Setup: \(facts.stateLabel). Open the log")
            .usageID("task-setup", label: "Task setup")
        }
    }

    /// What the line says: the commands resolved from the repositories, or the ones the log says ran. Resolution
    /// is asked once per task; until then the log's headers stand in.
    private var facts: (command: String, stateLabel: String)? {
        let setup = task.record.setup
        let commands = task.setupCommands ?? SetupLog.commands(in: setup?.log ?? "")
        let ran = [.running, .succeeded, .failed].contains(task.record.setupState)
        guard ran || !commands.isEmpty else { return nil }
        return (commands.joined(separator: " · "), task.record.setupState.rawValue)
    }
}

/// The state of a setup on an 18 pt chip: `● running · 18 s` in the running colour while it runs, `✓ 42 s` in
/// the passing colour, `✗ 42 s` in the failing one, *not run* / *skipped* in grey. The seconds tick while running;
/// under Reduce Motion the digits change without animating.
struct SetupStateChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let setup: TaskSetupRecord?

    var body: some View {
        if setup?.state == .running, let started = setup?.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = "running · \(DurationText.short(context.date.timeIntervalSince(started)))"
                chip(text, color: ThreadStateStyle.running, dot: true)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .default, value: text)
            }
        } else {
            switch setup?.state {
            case .succeeded: chip("✓" + duration, color: PullRequestStyle.passing)
            case .failed: chip("✗" + duration, color: PullRequestStyle.failing)
            case .skipped: chip("skipped", color: nil)
            case .running, .notRun, .none: chip("not run", color: nil)
            }
        }
    }

    private var duration: String {
        guard let started = setup?.startedAt, let finished = setup?.finishedAt else { return "" }
        return " " + DurationText.short(finished.timeIntervalSince(started))
    }

    private func chip(_ text: String, color: Color?, dot: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dot, let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(color ?? Ink.tertiary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color?.opacity(0.1) ?? Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .fixedSize()
        .accessibilityLabel("Setup \(text)")
    }
}

/// The ports lines: `Ports · block 4310–4319`, then the chips of the ports something listens on (`AppModel+Ports`)
/// and one line per process behind them — a dot, the command line, the thread it was started from or its pid — or
/// *nothing listening*. The processes are read while the card is open, with the ports.
private struct TaskPortsRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CardRowGlyph("network")
                Text("Ports")
                    .font(.system(size: 12, weight: .semibold))
                if let block = task.record.portBlock {
                    Text("block \(String(block.range.lowerBound))–\(String(block.range.upperBound - 1))")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .help("Every thread of the task gets SCOPE_PORT=\(String(block.base)) and the nine ports after it")
                }
                Spacer(minLength: 0)
                if task.listeningPorts.isEmpty {
                    Text("nothing listening")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            if !task.listeningPorts.isEmpty {
                TaskPortChips(task: task, compact: true)
                    .padding(.leading, 24)
                ForEach(task.listeningProcesses) { process in
                    ListeningProcessRow(task: task, process: process)
                }
            }
        }
        .padding(.vertical, 4)
        .usageID("task-servers", label: "Task servers")
        .onAppear { model.watchListeningProcesses(of: task, true) }
        .onDisappear { model.watchListeningProcesses(of: task, false) }
        .onChange(of: task.id) { old, _ in
            if let previous = model.task(old) { model.watchListeningProcesses(of: previous, false) }
            model.watchListeningProcesses(of: task, true)
        }
    }
}

/// One process that listens on a port of the task's block: the command line cut in the middle, and at the right
/// the thread it belongs to when that could be told, else its pid.
private struct ListeningProcessRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let process: ListeningProcesses.Process

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ThreadStateStyle.running)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(process.commandLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(process.commandLine)\npid \(String(process.pid)) · \(ports)")
            Spacer(minLength: 4)
            Text(owner)
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 140, alignment: .trailing)
                .help(process.threadID.map { "Started from the thread \(owner) (\($0))" } ?? "No thread of the task is its ancestor")
        }
        .padding(.leading, 5)
        .frame(height: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(process.commandLine), \(owner), \(ports)")
    }

    private var ports: String {
        (process.ports.count == 1 ? "port " : "ports ") + process.ports.map(String.init).joined(separator: ", ")
    }

    /// The thread's title while it lives; a thread since closed, or none found, leaves the pid.
    private var owner: String {
        if let raw = process.threadID, let id = ThreadID(rawValue: raw), let session = model.session(id) {
            return model.displayTitle(for: session)
        }
        return "pid \(String(process.pid))"
    }
}

/// The foot of the card: `This Mac · 312 MB on disk · 2 h 14 of agent time` — the disk once measured
/// (`AppModel+DiskUsage`), the agent time from the task's timeline totals, refreshed every minute.
private struct TaskMachineRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        let _ = model.threads(in: task.id).map { ($0.turnRevision, $0.displayState) }
        let _ = task.timelineLog
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                CardRowGlyph("laptopcomputer")
                    .padding(.trailing, 8)
                Text(caption(now: context.date))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(help)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
        .frame(height: 22)
        .usageID("task-disk", label: "Task disk usage")
        .task(id: task.id) {
            if task.timelineLog == nil { await model.reloadTimelineLog(of: task.id) }
        }
    }

    private func caption(now: Date) -> String {
        var parts = ["This Mac"]
        if let usage = task.diskUsage { parts.append("\(SandboxSize.text(usage.bytes)) on disk") }
        let agent = TaskTimeline.totals(createdAt: task.record.createdAt, archivedAt: task.record.archivedAt, now: now,
                                        lanes: model.timelineLanes(of: task)).agent
        if agent >= 1 { parts.append("\(DurationText.short(agent)) of agent time") }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        var lines = ["The task runs on this machine, in its sandboxes."]
        if let usage = task.diskUsage {
            lines.append("Disk measured \(usage.measuredAt.formatted(.relative(presentation: .named))).")
        }
        lines.append("Agent time is every thread's turns added up, since the task was created.")
        return lines.joined(separator: " ")
    }
}
