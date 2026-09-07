import SwiftUI
import ScopeCore

/// Sidebar row for a thread: driver icon, title, trailing caption (`scope root` / repo path), state dot.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession

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

            Spacer(minLength: 4)

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            StateDot(state: session.displayState)
        }
        .padding(.leading, 16)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(session.record.cwd)
        .contextMenu { contextMenu }
    }

    private var isSelected: Bool {
        model.selectedThreadID == session.id
    }

    private var caption: String {
        switch session.record.cwdKind {
        case .scopeRoot: "scope root"
        case .repoBase(let relativePath): relativePath
        case .task(let slug): slug
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
