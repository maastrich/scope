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
/// The trailing group lays out from the right: the state dot at a fixed inset, then a 16 pt gutter that is always
/// reserved (the hover close button lands in it, so nothing moves when the pointer arrives), then the caption,
/// which takes what is left and truncates. Nothing here has a fixed width, so a narrow sidebar shortens the
/// caption and then the title, and never pushes the dot off the edge.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ThreadSession
    /// 0 for a scope-level thread (Threads section), 1 under a task.
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

            if session.displayState.needsAttention {
                Text(session.displayState == .waiting(reason: .permission) ? "permission" : "needs you")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color("WarningText"))
                    .lineLimit(1)
            } else if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Always in the layout, so the close button appearing on hover moves nothing. Not clickable while
            // invisible: an unseen ✕ next to the state dot would close threads by accident (⌘W and the context
            // menu stay the keyboard path).
            closeButton
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)

            StateDot(state: session.displayState)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .overlay(alignment: .leading) {
            // A blocked thread does nothing until you answer: it is the loudest thing the sidebar has to say, and
            // a 6 pt dot at the far edge was the quietest way to say it.
            if session.displayState.needsAttention {
                // Inset and rounded so it sits inside the List's selection background rather than sticking out
                // to the left of it when the row is also the selected one.
                Capsule()
                    .fill(ThreadStateStyle.waiting)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 4)
            }
        }
        .contentShape(Rectangle())
        .help(session.record.cwd)
        .onTapGesture(count: 2) { model.promptRenameThread(session.id) }
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .contextMenu { contextMenu }
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
        .buttonStyle(.plain)
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

    @ViewBuilder
    private var contextMenu: some View {
        Button("Relaunch") {
            Task { await model.relaunch(session.id) }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(session.isAlive)
        Button("Resume") {
            Task { await model.resume(session.id) }
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
        Button("Close", role: .destructive) {
            Task { _ = await model.close(session.id, force: false) }
        }
        .keyboardShortcut("w", modifiers: .command)
    }
}
