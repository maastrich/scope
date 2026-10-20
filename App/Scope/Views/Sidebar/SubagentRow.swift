import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore

/// The sub-agents of a Claude Code thread, hung under its row (or under its task's row when the task row stands for
/// the thread): the ones running, and for `ClaudeSubagents.linger` the ones that just finished
/// (`ClaudeSubagents.sidebar`). One compact line each — what it was asked to do, and its state as the one trailing
/// dot — like every other row since PR 84: no glyph in front, nothing that pushes the dot off the edge. A click
/// selects the thread and opens the Subagents card on that sub-agent; nothing here stops one.
///
/// `now` is the sidebar's clock (`SidebarView.subagentClock`), so a finished sub-agent leaves when its time is up
/// rather than at the next unrelated change.
struct SubagentRows: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession
    /// The rows' own depth: one below the row they hang from.
    let depth: Int
    let now: Date

    var body: some View {
        let shown = session.claude.subagents.sidebar(now: now, alive: session.isAlive)
        ForEach(shown.agents) { agent in
            SubagentRow(agent: agent, session: session, depth: depth,
                        nesting: SidebarNesting(parentDepth: depth - 1, isLast: agent.id == shown.agents.last?.id && shown.more == 0))
        }
        if shown.more > 0 {
            SubagentMoreRow(session: session, count: shown.more, depth: depth,
                            nesting: SidebarNesting(parentDepth: depth - 1, isLast: true))
        }
    }
}

private struct SubagentRow: View {
    @Environment(AppModel.self) private var model
    let agent: ClaudeSubagents.Agent
    let session: ThreadSession
    let depth: Int
    let nesting: SidebarNesting

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Text(SubagentStyle.title(agent))
                .font(.scopeCaption)
                .foregroundStyle(agent.state.isRunning ? Ink.secondary : Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            SidebarStateDot(state: SubagentStyle.dotState(agent.state), pulses: agent.state.isRunning)
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: false))
        .sidebarNested(nesting)
        .contentShape(Rectangle())
        .onTapGesture { model.revealSubagent(agent.id, of: session) }
        .help(SubagentStyle.help(agent, now: .now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sub-agent \(SubagentStyle.title(agent)), \(SubagentStyle.label(agent.state))")
        .accessibilityAddTraits(.isButton)
        .selectionDisabled()
        .sidebarRow(selected: false)
        .usageID("sidebar.subagent", label: "Open a sub-agent")
    }
}

/// `3 more sub-agents running`: what does not fit under the thread, one click from the card that lists them all.
private struct SubagentMoreRow: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession
    let count: Int
    let depth: Int
    let nesting: SidebarNesting

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Text("\(count) more running")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarStateDot(state: nil)
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: false))
        .sidebarNested(nesting)
        .contentShape(Rectangle())
        .onTapGesture { model.revealSubagent(nil, of: session) }
        .help("Every sub-agent of this thread is in the Subagents card")
        .selectionDisabled()
        .sidebarRow(selected: false)
    }
}

/// How a sub-agent reads wherever the app shows one.
enum SubagentStyle {
    /// What it was asked to do, else its type.
    static func title(_ agent: ClaudeSubagents.Agent) -> String {
        agent.description ?? agent.type ?? "Sub-agent"
    }

    /// The thread state whose dot says the same: running breathes, finished is done, stopped and interrupted are an
    /// empty ring like a thread whose process is gone.
    static func dotState(_ state: ClaudeSubagents.State) -> ThreadState {
        switch state {
        case .running: .running
        case .completed: .done
        case .failed: .failed
        case .stopped, .interrupted: .exited
        }
    }

    static func label(_ state: ClaudeSubagents.State) -> String {
        switch state {
        case .running: "running"
        case .completed: "finished"
        case .failed: "failed"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        }
    }

    static func help(_ agent: ClaudeSubagents.Agent, now: Date) -> String {
        var parts = [label(agent.state)]
        if let type = agent.type { parts.append(type) }
        if let seconds = agent.duration(now: now) { parts.append(SubagentList.duration(Int(seconds.rounded()))) }
        if let tokens = agent.tokens { parts.append("\(TokenUsageText.compact(tokens)) tokens") }
        return "\(title(agent))\n" + parts.joined(separator: " · ")
    }
}
