import SwiftUI
import ScopeCore

/// Sidebar row for a thread: driver icon, title, trailing caption (`scope root` / repo path; none under a task,
/// the indentation already says "sandbox"), state dot. The trailing group has a fixed width so dots line up.
/// The row of the thread the scene shows carries an accent bar and a bold title — the sidebar is the only
/// thread switcher, so it has to say which one is live even when the List highlights the task row instead.
/// Hovering swaps the caption for a close button.
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
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            Text(model.displayTitle(for: session))
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if isHovered {
                closeButton
            } else if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 64, alignment: .trailing)
            }

            StateDot(state: session.displayState)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    private var isSelected: Bool {
        model.selectedThreadID == session.id
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
