import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore

/// The Background card: what the task's Claude Code threads run or have scheduled in the background
/// (`ClaudeBackgroundWork`). Closed, `2 running`, *finished 2m ago* or *nothing running*; open, per thread, the running shells and
/// Monitors first — what they run and for how long — then the ones that finished lately with their exit code, then
/// the `/loop` wake-up and the crons. A click on a task shows the end of its output, refreshed while it is shown; a
/// running one can be stopped from its row, after a confirmation.
struct BackgroundCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .background, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(threads(of: task)) }
        } actions: {
            EmptyView()
        } content: {
            if let task { content(threads(of: task)) }
        }
    }

    /// The task's threads that have background work, in sidebar order.
    private func threads(of task: TaskState) -> [ThreadSession] {
        model.threads(in: task.id).filter { !$0.claude.background.isEmpty }
    }

    @ViewBuilder
    private func summary(_ threads: [ThreadSession]) -> some View {
        // Ticks so a Monitor that expires while the card is closed stops counting as running.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let running = threads.reduce(0) { $0 + $1.claude.background.running(at: context.date).count }
            let scheduled = threads.reduce(0) { $0 + $1.claude.background.crons.count + ($1.claude.background.wakeup == nil ? 0 : 1) }
            if running > 0 {
                Text("\(running) running").monospacedDigit()
            } else if scheduled > 0 {
                Text("\(scheduled) scheduled").monospacedDigit().foregroundStyle(Ink.secondary)
            } else if let ended = threads.flatMap(\.claude.background.tasks).compactMap(\.endedAt).max(),
                      context.date.timeIntervalSince(ended) < 3600 {
                // The final state a card keeps while it lingers on Overview before going down to Details.
                let age = InboxAge.label(ended, now: context.date)
                Text(age == "now" ? "finished just now" : "finished \(age) ago").foregroundStyle(Ink.secondary)
            } else {
                Text("nothing running").foregroundStyle(Ink.tertiary)
            }
        }
    }

    @ViewBuilder
    private func content(_ threads: [ThreadSession]) -> some View {
        if threads.isEmpty {
            CardEmptyState(title: "Nothing in the background",
                           detail: "Commands an agent sends to the background, its Monitors, /loop wake-ups and crons appear here.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(threads) { thread in
                    BackgroundThreadGroup(thread: thread, titled: threads.count > 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// One thread's background work: running, recent, scheduled.
private struct BackgroundThreadGroup: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSession
    let titled: Bool

    var body: some View {
        let work = thread.claude.background
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let running = work.tasks.filter { $0.status(at: now).isRunning }
            let recent = work.tasks.filter { !$0.status(at: now).isRunning }
                .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
                .prefix(BackgroundWorkReport.recentLimit)
            VStack(alignment: .leading, spacing: 0) {
                if titled {
                    Text(thread.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                if !running.isEmpty {
                    CardGroupLabel("Running", count: running.count)
                    ForEach(running) { task in row(task, now: now) }
                }
                if !recent.isEmpty {
                    CardGroupLabel("Finished")
                        .padding(.top, running.isEmpty ? 0 : 4)
                    ForEach(Array(recent)) { task in row(task, now: now) }
                }
                if work.wakeup != nil || !work.crons.isEmpty {
                    CardGroupLabel("Scheduled")
                        .padding(.top, 4)
                    if let wakeup = work.wakeup { BackgroundWakeupRow(wakeup: wakeup, now: now) }
                    ForEach(work.crons) { cron in BackgroundCronRow(cron: cron) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ task: ClaudeBackgroundWork.Task, now: Date) -> some View {
        let expanded = model.inspector.backgroundOutput == task.id
        BackgroundTaskRow(thread: thread, task: task, now: now, expanded: expanded) {
            withAnimation(.easeOut(duration: 0.12)) { model.inspector.backgroundOutput = expanded ? nil : task.id }
        }
        if expanded {
            BackgroundOutputView(thread: thread, task: task)
                .padding(.leading, 24)
                .padding(.bottom, 6)
        }
    }
}

/// `npm run dev    12m` — glyph, what it runs, how long or how it ended; Stop on hover while it runs.
private struct BackgroundTaskRow: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSession
    let task: ClaudeBackgroundWork.Task
    let now: Date
    let expanded: Bool
    var toggle: () -> Void
    @State private var hovering = false
    @State private var stopping = false

    var body: some View {
        let status = task.status(at: now)
        HStack(spacing: 8) {
            CardRowGlyph(task.kind == .monitor ? "dot.radiowaves.left.and.right" : "terminal")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.description ?? task.command ?? task.id)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let command = task.command, task.description != nil {
                    Text(command)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if hovering, thread.canStopBackgroundTask(task, now: now) {
                Button {
                    Task { await stop() }
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .disabled(stopping)
                .help("Stop \(task.id)… — signals its process; asks first")
                .accessibilityLabel("Stop background task \(task.id)")
            }
            BackgroundStatusText(task: task, status: status, now: now)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .help(task.command ?? task.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Hides its output" : "Shows its output")
        .usageID("inspector.background.task", label: "Background task output")
    }

    private func stop() async {
        let what = task.kind == .monitor ? "Monitor" : "command"
        let detail = """
            “\(task.command ?? task.description ?? task.id)” — \(thread.title). Scope signals its process; \
            Claude Code then tells the agent the \(what) failed, and the agent may start it again.
            """
        guard await model.confirmForce(title: "Stop this background \(what)?", detail: detail, button: "Stop") else { return }
        stopping = true
        defer { stopping = false }
        await model.stopBackgroundTask(task.id, of: thread)
    }
}

/// `12m` while it runs; `exit 0`, `exit 2`, `killed`, `stopped from Scope`… once over.
private struct BackgroundStatusText: View {
    let task: ClaudeBackgroundWork.Task
    let status: ClaudeBackgroundWork.Status
    let now: Date

    var body: some View {
        Text(text)
            .font(.scopeValue)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var text: String {
        switch status {
        case .running:
            let since = task.startedAt.map { BackgroundWorkReport.duration(now.timeIntervalSince($0)) } ?? "running"
            if let expires = task.expiresAt { return since + " · " + BackgroundWorkReport.duration(expires.timeIntervalSince(now)) + " left" }
            return since
        case _ where task.stoppedFromScope:
            return "stopped"
        case .completed(let code): return code.map { "exit \($0)" } ?? "done"
        case .failed(let code): return code.map { "exit \($0)" } ?? "failed"
        case .killed: return "killed"
        case .stopped: return "stopped"
        case .expired: return "expired"
        case .ended: return "ended"
        }
    }

    private var color: Color {
        switch status {
        case .running: ThreadStateStyle.running
        case _ where task.stoppedFromScope: Ink.tertiary
        case .completed(let code): code.map { $0 == 0 ? PullRequestStyle.passing : PullRequestStyle.failing } ?? Ink.secondary
        case .failed: PullRequestStyle.failing
        default: Ink.tertiary
        }
    }
}

/// The end of the task's output file, in monospace, read again every two seconds while it is shown; a Monitor's last
/// events above it.
private struct BackgroundOutputView: View {
    let thread: ThreadSession
    let task: ClaudeBackgroundWork.Task
    @State private var output: FileTail.Result?

    static let refresh: Duration = .seconds(2)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !task.events.isEmpty {
                Text(task.eventCount > task.events.count ? "Last \(task.events.count) of \(task.eventCount) events" : "Events")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                ForEach(Array(task.events.enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            switch output {
            case nil:
                ProgressView().controlSize(.small)
            case .missing?:
                note(path == nil ? "Claude Code did not say where its output goes."
                     : "The output file is gone — Claude Code removes it with its session.")
            case .unreadable?:
                note("The output file cannot be read.")
            case .text(let text, let truncated, _)?:
                if text.isEmpty {
                    note("No output yet.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                if truncated {
                                    Text("… earlier output not shown")
                                        .font(.scopeCaption)
                                        .foregroundStyle(Ink.tertiary)
                                }
                                Text(text)
                                    .font(.scopeValue)
                                    .foregroundStyle(Ink.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 180)
                        .background(Surface.ground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke, lineWidth: 1)
                        }
                        .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
            if let path {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    CopyButton(label: "Copy the output file's path") { path }
                }
            }
        }
        .task(id: task.id) {
            while !Task.isCancelled {
                if let path {
                    let next = await AppModel.readBackgroundOutput(path)
                    if next != output { output = next }
                } else {
                    output = .missing
                }
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    private var path: String? {
        ClaudeBackgroundWork.outputFile(of: task, transcriptPath: thread.activity.transcriptPath)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.scopeCaption)
            .foregroundStyle(Ink.tertiary)
            .padding(.vertical, 2)
    }
}

/// `/loop wake-up · in 12m — <reason>`.
private struct BackgroundWakeupRow: View {
    let wakeup: ClaudeBackgroundWork.Wakeup
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            CardRowGlyph("alarm")
            Text(wakeup.reason ?? "/loop wake-up")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(wakeup.scheduledFor > now ? "in " + BackgroundWorkReport.duration(wakeup.scheduledFor.timeIntervalSince(now)) : "due")
                .font(.scopeValue)
                .foregroundStyle(Ink.secondary)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .help(wakeup.prompt ?? "")
    }
}

/// `<prompt>    7 * * * *` — a cron of the session; recurring or once.
private struct BackgroundCronRow: View {
    let cron: ClaudeBackgroundWork.Cron

    var body: some View {
        HStack(spacing: 8) {
            CardRowGlyph(cron.recurring == false ? "calendar" : "repeat")
            Text(cron.prompt ?? cron.id)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(cron.humanSchedule ?? cron.schedule ?? "")
                .font(.scopeValue)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .help(cron.recurring == false ? "Fires once" : "Recurring — Claude Code expires it after seven days")
    }
}
