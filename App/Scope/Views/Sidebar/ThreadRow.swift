import SwiftUI
import ScopeControl
import ScopeCore

/// Sidebar row for a thread: title, trailing caption (`scope root` / repo path; none under a task, the rule from
/// its row already says "sandbox"), state dot. No driver icon: the terminal on the right shows which driver runs.
/// A detailed row's second line is what the agent is doing (`ThreadActivityCaption`) whenever its driver has said,
/// and the state and the place otherwise. A row nested under a task or **Loose threads** hangs from that row's
/// rule (`SidebarNesting`).
///
/// One row at a time may look selected, and it is the List's: the thread the scene shows used to carry an accent
/// bar and a bold title of its own, which read as a second selection whenever the List highlighted the task row
/// instead. It now carries a quiet, un-accented marker, and only while it is *not* the selected row — when it is,
/// the highlight already says so.
///
/// A waiting thread says so once, with the dot's square shape (`StateDot`). The red bar down the row and the
/// *needs you* caption that used to come with it made three signals for one fact.
///
/// The trailing group lays out from the right: the state dot at a fixed inset, then the caption, which takes what
/// is left and truncates. The close button appears on hover over the end of the caption, left of the dot, and the
/// text fades out under it, so no width is held open for it. Nothing here has a fixed width, so a narrow sidebar shortens the caption and
/// then the title, and never pushes the dot off the edge.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ThreadSession
    /// 1 under a task or the loose-threads group, and among the tasks of a state group: a thread row has no
    /// disclosure slot, so one level of indent is what puts its title in the column of a task's name.
    var depth = 0
    /// Set under a task or the loose-threads group: the rule from the parent's chevron runs down this row.
    var nesting: SidebarNesting? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayTitle(for: session))
                    .font(.scopeBody)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if detailed, let headline {
                    ThreadActivityCaption(headline: headline, readReply: headline.opensReply ? { model.readReply(of: session) } : nil)
                } else if detailed {
                    Text([session.displayState.displayLabel, caption].compactMap { $0 }.joined(separator: " · "))
                        .font(.scopeCaption)
                        .foregroundStyle(captionInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)

            if session.record.resolvedOrigin.openedByAgent {
                OriginMarker()
            }

            if showsLiveMarker {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(captionInk)
                    .accessibilityLabel("Shown in the terminal")
            }

            Spacer(minLength: 4)

            // In a detailed row the caption is on the second line, after the state.
            if let caption, !detailed {
                Text(caption)
                    .font(.scopeCaption)
                    .foregroundStyle(captionInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            SidebarStateDot(state: session.displayState, pulses: session.isWorking)
        }
        // A resident thread has no close button: it cannot be closed.
        .sidebarHoverControls(isHovered && session.record.resident == nil) { closeButton }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.rowHeight(detailed: detailed))
        .sidebarNested(nesting)
        .contentShape(Rectangle())
        // Left of the state dot, over the caption: the row's number among the scope's threads (⌘1…⌘9, the menu's
        // order) and ⌥↩ when a reply can go under the row.
        .keyHints(.custom(.trailing, CGSize(width: -(SidebarMetrics.stateDotColumn + 6), height: 0))) { rowHints }
        .help(helpText)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .sidebarRow(selected: isListSelected)
        .contextMenu { ThreadMenuItems(session: session) }
        .accessibilityAddTraits(isListSelected ? .isSelected : [])
    }

    private var closeButton: some View {
        Button {
            Task { _ = await model.close(session.id, force: false) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.iconTight)
        .help("Close Thread (⌘W)")
        .accessibilityLabel("Close \(model.displayTitle(for: session))")
    }

    private var rowHints: [String] {
        var hints: [String] = []
        if let scope = model.currentScope,
           let index = model.threadOrder(in: scope.id).firstIndex(where: { $0.id == session.id }),
           let keys = CommandKeyHints.shared.keys(for: KeyHintIndex.threadID(index + 1)) {
            hints.append(keys)
        }
        if model.canReply(to: session) { hints.append("⌥↩") }
        return hints
    }

    // The selected row is a neutral fill (`sidebarRow`), so the caption keeps its ordinary tier.
    private var captionInk: Color { Ink.tertiary }

    /// Settings ▸ Sidebar ▸ Rows: a second line with the state in words and where the thread runs.
    private var detailed: Bool { model.config.preferences.sidebarRows == .detailed }

    /// The thread the scene shows: where typing goes.
    private var isLive: Bool {
        model.selectedThreadID == session.id
    }

    /// The row the List highlights.
    private var isListSelected: Bool {
        model.selection == .thread(session.id)
    }

    /// Only worth drawing when the highlight is elsewhere — on a task row, say.
    private var showsLiveMarker: Bool {
        isLive && !isListSelected
    }

    private var failureText: String? {
        ThreadNotificationContent.failureDescription(session.lastFailure)
    }

    private var headline: ThreadActivityHeadline? {
        session.activityHeadline(model.config.preferences.finishedThreadLine)
    }

    private var helpText: String {
        "\(session.displayState.displayLabel)\(failureText.map { ": \($0)" } ?? "") — \(session.record.cwd)"
            + ((detailed ? headline?.detail : nil).map { "\n\($0)" } ?? "")
            + (originText.map { "\n\($0)" } ?? "") + (residentText.map { "\n\($0)" } ?? "")
    }

    private var residentText: String? {
        switch session.record.resident {
        case .orchestrator: "The scope's orchestrator: always here while the scope is declared. Stop (⌘.) halts it; it cannot be closed."
        case .terminal: "The scope's terminal: always here while the scope is declared. Stop (⌘.) halts it; it cannot be closed."
        case nil: nil
        }
    }

    /// Who opened it, when that was an agent: the parent thread by its title, or the client's own name.
    private var originText: String? {
        let origin = session.record.resolvedOrigin
        guard origin.openedByAgent else { return nil }
        let parent = origin.parent.flatMap { ThreadID(rawValue: $0) }.flatMap { model.session($0) }
        let opener = parent.map { "“\(model.displayTitle(for: $0))”" } ?? "an agent outside Scope"
        return "Opened by \(opener)" + (origin.client.map { " (\($0))" } ?? "")
    }

    private var caption: String? {
        switch session.record.cwdKind {
        case .scopeRoot: "scope root"
        case .repoBase(let relativePath): relativePath
        case .task: depth >= 1 ? nil : (model.task(of: session)?.name ?? "task")
        }
    }
}

/// A thread's own actions: its row's context menu, and the task row's when the task has only that thread.
struct ThreadMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession

    var body: some View {
        Button("Reply…") {
            model.beginReply(to: session.id)
        }
        .disabled(!model.canReply(to: session))
        Button("Read Reply") {
            model.readReply(of: session)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Mark as Read") {
            model.markRead(session.id)
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(session.displayState.acknowledged == session.displayState)
        if session.assistNote?.isStuck == true {
            Button("Not Stuck") {
                model.markNotStuck(session.id)
            }
            .usageID("sidebar.thread.not-stuck", label: "Not stuck")
        }
        Divider()
        Button("Relaunch") {
            Task { await model.relaunch(session.id) }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(session.isAlive)
        // Relaunch resumes when it can; this is the way to a new session instead.
        Button("Start Fresh") {
            Task { await model.startFresh(session.id) }
        }
        .disabled(session.isAlive || !session.canResume)
        // A resident thread starts with its scope whatever this says.
        if session.record.resident == nil {
            Toggle("Relaunch When Scope Opens", isOn: Binding(
                get: { session.record.relaunchesAtStartup },
                set: { session.setRelaunchesAtStartup($0) }
            ))
            .disabled(!model.config.preferences.autoRelaunchThreads)
        }
        Button("Stop") {
            model.stop(session.id)
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!session.isAlive)
        Divider()
        Button("Rename…") {
            model.promptRenameThread(session.id)
        }
        Button("Open in Editor") {
            model.openInEditor(thread: session.id)
        }
        .keyboardShortcut("e", modifiers: .command)
        if let task = model.task(of: session) {
            Button("Open Task in Editor") {
                model.openTaskInEditor(task)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        Button("Reveal cwd in Finder") {
            Reveal.inFinder(URL(fileURLWithPath: session.reportedDirectory ?? session.record.cwd, isDirectory: true))
        }
        Button("Copy SCOPE_THREAD") {
            Pasteboard.copy(session.id.rawValue)
        }
        if session.record.resident == nil {
            Divider()
            Button("Close Thread", role: .destructive) {
                Task { _ = await model.close(session.id, force: false) }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
