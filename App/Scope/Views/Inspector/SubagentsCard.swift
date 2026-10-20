import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeDrivers

/// The Subagents card: what the task's Claude Code threads handed to sub-agents (`ClaudeSubagents`). Closed,
/// `1 running · 4 done`, else *none*. Open, one row per sub-agent, newest first — its state as a dot, what it was
/// asked to do, its type, model, duration, tokens and tool calls — grouped by thread when the task has several. A
/// click opens the detail under the row: the start of its report, the last tools it ran (read from its own transcript
/// while the detail is open), where it ran. The card reads: nothing here stops a sub-agent.
struct SubagentsCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let threads = model.currentTask.map { model.threads(in: $0.id) } ?? []
        CollapsibleSection(section: .subagents, bodyHeight: bodyHeight, onNatural: onNatural) {
            summary(threads)
        } actions: {
            EmptyView()
        } content: {
            content(threads)
        }
    }

    @ViewBuilder
    private func summary(_ threads: [ThreadSession]) -> some View {
        let summaries = threads.flatMap { SubagentList.summaries($0.claude.subagents, now: .now, alive: $0.isAlive, recent: nil) ?? [] }
        let text = SubagentList.column(summaries)
        Text(text.isEmpty ? "none" : text)
            .foregroundStyle(text.isEmpty ? Ink.tertiary : Ink.secondary)
    }

    @ViewBuilder
    private func content(_ threads: [ThreadSession]) -> some View {
        let launched = threads.filter { !$0.claude.subagents.agents.isEmpty }
        if launched.isEmpty {
            CardEmptyState(title: "No sub-agent yet",
                           detail: "What Claude Code hands to a sub-agent (the Agent tool) appears here, with its state, duration and tokens.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(launched, id: \.id) { session in
                    if launched.count > 1 || threads.count > 1 {
                        CardGroupLabel(model.displayTitle(for: session), count: session.claude.subagents.agents.count)
                    }
                    ForEach(session.claude.subagents.agents.reversed()) { agent in
                        SubagentCardRow(agent: agent, session: session)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// One sub-agent: the dot, what it was asked, and under it `Explore · haiku · 1m 33s · 51k tokens · 17 tools`; its
/// detail below when it is the thread's `focusedSubagent`.
private struct SubagentCardRow: View {
    let agent: ClaudeSubagents.Agent
    let session: ThreadSession
    @State private var hovering = false

    private var isOpen: Bool { session.focusedSubagent == agent.id }
    private var state: ClaudeSubagents.State { agent.state(alive: session.isAlive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                session.focusedSubagent = isOpen ? nil : agent.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StateDot(state: SubagentStyle.dotState(state), size: 7, pulses: state.isRunning)
                        .frame(width: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SubagentStyle.title(agent))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(isOpen ? 3 : 1)
                            .truncationMode(.tail)
                        caption
                    }
                    Spacer(minLength: 4)
                    Text(SubagentStyle.label(state))
                        .font(.scopeCaption)
                        .foregroundStyle(state == .failed ? ThreadStateStyle.failed : Ink.tertiary)
                        .fixedSize()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(hovering || isOpen ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -4)
            .onHover { hovering = $0 }
            .help(SubagentStyle.help(agent, now: .now))
            .accessibilityLabel("\(SubagentStyle.title(agent)), \(SubagentStyle.label(state))")
            .accessibilityHint(isOpen ? "Hides its detail" : "Shows its report and its last tools")
            .usageID("inspector.subagents.row", label: "Open a sub-agent")
            if isOpen {
                SubagentDetail(agent: agent, session: session)
                    .padding(.leading, 24)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Read off the clock while it runs, so its duration moves.
    @ViewBuilder
    private var caption: some View {
        if state.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                captionText(now: context.date)
            }
        } else {
            captionText(now: .now)
        }
    }

    private func captionText(now: Date) -> some View {
        var parts: [String] = []
        if let type = agent.type { parts.append(type) }
        if let model = agent.model { parts.append(ModelLabel.line(model: model, reportedName: nil, driver: nil, driverVersion: nil) ?? model) }
        if let seconds = agent.duration(now: now) { parts.append(SubagentList.duration(Int(seconds.rounded()))) }
        if let tokens = agent.tokens { parts.append("\(TokenUsageText.compact(tokens)) tokens") }
        if let tools = agent.toolUses { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if agent.background == true { parts.append("background") }
        return Text(parts.joined(separator: " · "))
            .font(.scopeCaption.monospacedDigit())
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The detail of one sub-agent: the start of its report, its last tool calls, where it ran and its transcript.
private struct SubagentDetail: View {
    let agent: ClaudeSubagents.Agent
    let session: ThreadSession
    @State private var tail = ClaudeSubagentTail()

    /// How often the transcript of a running sub-agent is looked at again while its detail is open.
    static let refresh: Duration = .seconds(2)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = agent.result {
                CardGroupLabel("Report")
                Text(result)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(14)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if agent.state(alive: session.isAlive).isRunning {
                Text("No report yet: it is still at work.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }
            if !tail.steps.isEmpty {
                CardGroupLabel(tail.count > tail.steps.count ? "Last tools · \(tail.count) in all" : "Tools", count: tail.steps.count)
                ForEach(tail.steps.reversed()) { step in
                    HStack(spacing: 6) {
                        Text(step.tool)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize()
                        if let target = step.target {
                            Text(target)
                                .font(.scopeValue)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if let worktree = agent.worktreePath {
                CardGroupLabel("Worktree")
                Text(agent.worktreeBranch.map { "\($0) · \(worktree)" } ?? worktree)
                    .font(.scopeValue)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let url = transcriptURL {
                Button("Reveal its transcript in Finder") { Reveal.inFinder(url) }
                    .buttonStyle(.link)
                    .font(.scopeCaption)
                    .padding(.top, 2)
            }
        }
        .task(id: "\(transcriptURL?.path ?? "")|\(agent.state(alive: session.isAlive))") { await follow() }
    }

    private var transcriptURL: URL? {
        if let path = agent.transcriptPath { return URL(fileURLWithPath: path) }
        guard let id = agent.agentID, let session = session.activity.transcriptPath else { return nil }
        return ClaudeSubagents.transcriptURL(agentID: id, sessionTranscript: session)
    }

    /// Reads its transcript off the main thread, again every `refresh` while it runs.
    private func follow() async {
        guard let url = transcriptURL else { return }
        repeat {
            let start = tail
            let next = await Task.detached(priority: .utility) {
                var copy = start
                _ = try? copy.read(url)
                return copy
            }.value
            if next != tail { tail = next }
            guard agent.state(alive: session.isAlive).isRunning else { return }
            try? await Task.sleep(for: Self.refresh)
        } while !Task.isCancelled
    }
}
