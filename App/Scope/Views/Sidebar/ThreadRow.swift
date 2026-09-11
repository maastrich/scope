import SwiftUI
import ScopeCore

/// Sidebar row for a thread: driver icon, title, trailing caption (`scope root` / repo path; none under a task,
/// the indentation already says "sandbox"), state dot.
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
/// is left and truncates. The close button appears on hover over the end of the caption, which fades out under it,
/// so no width is held open for it. Nothing here has a fixed width, so a narrow sidebar shortens the caption and
/// then the title, and never pushes the dot off the edge.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ThreadSession
    /// 0 for a thread at the top level, 1 under a task or the loose-threads group.
    var depth = 0
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: session.profile.icon ?? "terminal")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(model.displayTitle(for: session))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if showsLiveMarker {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Shown in the terminal")
            }

            Spacer(minLength: 4)

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            StateDot(state: session.displayState)
        }
        // The dot stays visible under the pointer: only the caption gives way to the close button.
        .trailingFade(isHovered, width: 16 + 7, keeping: 8)
        .overlay(alignment: .trailing) {
            if isHovered {
                closeButton
                    .padding(.trailing, 8 + 7)
                    .transition(.opacity)
            }
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(session.record.cwd)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .contextMenu { ThreadMenuItems(session: session) }
        .accessibilityAddTraits(isListSelected ? .isSelected : [])
    }

    private var closeButton: some View {
        Button {
            Task { _ = await model.close(session.id, force: false) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.iconTight)
        .help("Close Thread (⌘W)")
        .accessibilityLabel("Close \(model.displayTitle(for: session))")
    }

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
        Button("Mark as Read") {
            model.markRead(session.id)
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(!session.displayState.needsAttention)
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
        .disabled(model.config.preferences.editor == nil)
        if let task = model.task(of: session) {
            Button("Open Task in Editor") {
                model.openTaskInEditor(task)
            }
            .disabled(model.config.preferences.editor == nil)
        }
        Button("Reveal cwd in Finder") {
            Reveal.inFinder(URL(fileURLWithPath: session.reportedDirectory ?? session.record.cwd, isDirectory: true))
        }
        Button("Copy SCOPE_THREAD") {
            Pasteboard.copy(session.id.rawValue)
        }
        Divider()
        Button("Close Thread", role: .destructive) {
            Task { _ = await model.close(session.id, force: false) }
        }
        .keyboardShortcut("w", modifiers: .command)
    }
}
