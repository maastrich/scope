import ScopeAdapters
import ScopeCore
import ScopeDrivers
import SwiftUI

/// The Connectors card: the MCP servers the task's live Claude Code threads talk to, and how each stands. Closed,
/// `3 · 1 needs auth`, `4 · 2 failed`, `3` or *none*; open, one row per server — trouble first — and one group per
/// thread when the threads disagree (`ConnectorsSummary`).
///
/// It reads what `ClaudeMCPServers` keeps from each thread's transcript and configuration, and acts on nothing:
/// re-authenticating is `/mcp` in the thread, so the *re-authenticate* chip only brings that thread forward. Other
/// drivers report no MCP servers, and the card says it only knows Claude Code. Hidden by default.
struct ConnectorsCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .connectors, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } actions: {
            EmptyView()
        } content: {
            if let task { content(task) }
        }
    }

    /// The task's live Claude Code threads, oldest first so the groups keep their place.
    private func claudeThreads(of task: TaskState) -> [ThreadSession] {
        model.threads(in: task.id).filter { $0.isAlive && Self.isClaudeCode($0) }
    }

    private func entries(_ sessions: [ThreadSession]) -> [ConnectorsSummary.Thread<ThreadID>] {
        sessions.map { ConnectorsSummary.Thread(id: $0.id, title: model.displayTitle(for: $0), servers: $0.claude.mcpServers.servers) }
    }

    /// The thread a merged row's `/mcp` belongs in: the first one where the server waits for a login.
    private func thread(waitingOn server: ClaudeMCPServers.Server, in sessions: [ThreadSession]) -> ThreadID? {
        guard server.status == .needsAuth else { return nil }
        return sessions.first { session in
            session.claude.mcpServers.servers.contains { $0.name == server.name && $0.status == .needsAuth }
        }?.id
    }

    static func isClaudeCode(_ session: ThreadSession) -> Bool {
        session.profile.adapter?.kind == ClaudeHooksAdapter.kind
    }

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        let sessions = claudeThreads(of: task)
        if sessions.isEmpty, model.threads(in: task.id).contains(where: \.isAlive) {
            Text("Claude Code only").foregroundStyle(Ink.tertiary)
        } else {
            let summary = ConnectorsSummary.summary(entries(sessions))
            if summary.count == 0 {
                Text("none").foregroundStyle(Ink.tertiary)
            } else {
                HStack(spacing: 0) {
                    Text("\(summary.count)")
                    if summary.needsAuth > 0 {
                        Text(" · ")
                        Text(summary.needsAuthText).foregroundStyle(PullRequestStyle.pending)
                    }
                    if summary.failed > 0 {
                        Text(" · ")
                        Text(summary.failedText).foregroundStyle(ThreadStateStyle.failed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        let sessions = claudeThreads(of: task)
        let groups = ConnectorsSummary.groups(entries(sessions))
        if sessions.isEmpty, model.threads(in: task.id).contains(where: \.isAlive) {
            CardEmptyState(title: "Claude Code only",
                           detail: "Scope reads MCP servers from Claude Code threads; this task runs other drivers.")
        } else if groups.isEmpty {
            CardEmptyState(title: "No MCP servers",
                           detail: "The servers a Claude Code thread connects to appear here.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.thread) { group in
                    ConnectorGroup(group: group) { server in group.thread ?? thread(waitingOn: server, in: sessions) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("Read from Claude Code's transcript and configuration · never edited by Scope")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// One list of servers, its thread's title above it when the card holds several, folded after `shortCount` rows
/// with *Show all N*: a Claude Code session with its claude.ai connectors and plugins easily lists twenty servers,
/// and trouble sorts first, so what is folded is what works.
private struct ConnectorGroup: View {
    let group: ConnectorsSummary.Group<ThreadID>
    let thread: (ClaudeMCPServers.Server) -> ThreadID?
    @State private var showAll = false

    static let shortCount = 10

    var body: some View {
        let servers = group.servers
        if let title = group.title { CardGroupLabel(title, count: servers.count) }
        ForEach(showAll ? servers : Array(servers.prefix(Self.shortCount))) { server in
            ConnectorRow(server: server, thread: thread(server))
        }
        if servers.count > Self.shortCount {
            Button(showAll ? "Show fewer" : "Show all \(servers.count)") { showAll.toggle() }
                .buttonStyle(.plain)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .padding(.top, 2)
                .padding(.leading, 24)
                .usageID("connectors.show-all", label: "Show every MCP server")
        }
    }
}

/// One server: plug, name, `· source · transport`, then `N tools · N calls` and its state — a dot, or the
/// *re-authenticate* chip when it waits for a login.
private struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    let server: ClaudeMCPServers.Server
    /// The thread to bring forward for `/mcp`.
    let thread: ThreadID?

    var body: some View {
        let light = ConnectorsSummary.light(server)
        HStack(spacing: 8) {
            CardRowGlyph("powerplug")
            HStack(spacing: 4) {
                Text(server.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let origin = origin {
                    Text("· \(origin)")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if light == .failed, let code = server.errorCode {
                Text(code)
                    .font(.scopeValue)
                    .foregroundStyle(ThreadStateStyle.failed)
                    .lineLimit(1)
                    .fixedSize()
            } else if light != .needsAuth, let usage {
                // A server waiting for a login lists only its `authenticate` tools: no count worth reading.
                Text(usage)
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if light == .needsAuth {
                Button {
                    // Only brings the thread forward: signing in is `/mcp`, typed there.
                    if let thread { model.selection = .thread(thread) }
                } label: {
                    Chip(text: "re-authenticate", tint: PullRequestStyle.pending)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Run /mcp in the thread to sign \(server.name) in again; Scope sends nothing")
                .accessibilityLabel("\(server.name) needs authentication: run /mcp in the thread")
            } else {
                Circle()
                    .fill(color(light))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 24)
        .help(help(light))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name), \(stateWord(light))")
    }

    /// `user · stdio`, `claude.ai`, … — what is known of where it is declared and how it is reached.
    private var origin: String? {
        let parts = [server.source?.rawValue, server.transport].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var usage: String? {
        var parts: [String] = []
        if server.tools > 0 { parts.append(server.tools == 1 ? "1 tool" : "\(server.tools) tools") }
        if server.toolCalls > 0 { parts.append(server.toolCalls == 1 ? "1 call" : "\(server.toolCalls) calls") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func color(_ light: ConnectorsSummary.Light) -> Color {
        switch light {
        case .connected: ThreadStateStyle.running
        case .pending: ThreadStateStyle.waiting
        case .failed: ThreadStateStyle.failed
        case .needsAuth: PullRequestStyle.pending
        case .notReported: ThreadStateStyle.idle
        }
    }

    private func stateWord(_ light: ConnectorsSummary.Light) -> String {
        switch light {
        case .connected: "connected"
        case .pending: "connecting"
        case .failed: "failed"
        case .needsAuth: "needs authentication"
        case .notReported: "not reported"
        }
    }

    private func help(_ light: ConnectorsSummary.Light) -> String {
        switch light {
        case .connected:
            server.evidence == .toolCalled ? "Connected — one of its tools was called" : "Connected — its tools are listed"
        case .pending: "Still connecting"
        case .failed:
            ["Failed", server.errorCode, server.error].compactMap { $0 }.joined(separator: " — ")
        case .needsAuth: "Needs authentication — run /mcp in the thread"
        case .notReported:
            server.status == .unknown
                ? "Not reported — declared in the configuration, Claude Code has said nothing about it yet"
                : "Not reported — in no trouble list, but none of its tools listed or called yet"
        }
    }
}
