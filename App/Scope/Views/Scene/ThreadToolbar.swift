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
            // Driver name and state pill never collapse; scope and cwd give way first.
            Image(systemName: session.profile.icon ?? "terminal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(session.profile.name)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
                .layoutPriority(2)
            if let scope {
                separator
                Text(scope.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            separator
            Text(abbreviatedDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 240, alignment: .leading)
                .help(currentDirectory)
                .accessibilityLabel("Working directory \(currentDirectory)")
            StatePill(state: session.displayState)
                .fixedSize()
                .layoutPriority(2)
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

    /// The last two path components (`…/acme/auth-refresh`); `~` for home and home-relative when shorter.
    /// The full path lives in the tooltip.
    private var abbreviatedDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = currentDirectory
        if path == home { return "~" }
        let relative = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return relative }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
