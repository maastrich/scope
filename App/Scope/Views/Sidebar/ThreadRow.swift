import SwiftUI
import ScopeCore

/// Sidebar row for a thread: driver icon, title, trailing caption (`scope root` / repo path; none under a task,
/// the indentation already says "sandbox"), state dot. The trailing group has a fixed width so dots line up.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession
    /// 1 for a scope-level thread, 2 under a task.
    var depth = 1

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: session.profile.icon ?? "terminal")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            Text(session.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if let caption {
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
        .contentShape(Rectangle())
        .help(session.record.cwd)
        .contextMenu { contextMenu }
    }

    private var isSelected: Bool {
        model.selectedThreadID == session.id
    }

    private var caption: String? {
        switch session.record.cwdKind {
        case .scopeRoot: "scope root"
        case .repoBase(let relativePath): relativePath
        case .task: depth == 2 ? nil : (model.task(of: session)?.name ?? "task")
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
        Button("Rename…") {}
            .disabled(true)
            .help("Thread renaming arrives with tasks in M2")
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
