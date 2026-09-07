import SwiftUI
import ScopeCore

/// Title group of the scene toolbar: driver icon · driver name · scope · cwd (mono, OSC 7 when reported) ·
/// state pill. The right-hand buttons live in `SceneView`'s toolbar so they stay in the toolbar's
/// `.primaryAction` slot.
struct ThreadToolbar: View {
    let session: ThreadSession
    let scope: ScopeState?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.profile.icon ?? "terminal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(session.profile.name)
                .font(.system(size: 13, weight: .semibold))
            if let scope {
                separator
                Text(scope.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            separator
            Text(abbreviatedDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320, alignment: .leading)
                .help(currentDirectory)
            StatePill(state: session.displayState)
        }
        .padding(.leading, 4)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
    }

    private var currentDirectory: String {
        session.reportedDirectory ?? session.record.cwd
    }

    /// Home-relative form, the way a prompt shows it.
    private var abbreviatedDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = currentDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
