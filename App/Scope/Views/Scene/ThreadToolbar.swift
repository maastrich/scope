import Foundation
import ScopeCore

/// What the window title says about the current thread: the driver as the title, `scope · cwd` as the
/// subtitle. Drawn by the system as the window's own title (`navigationTitle` / `navigationSubtitle`), which
/// truncates on its own and never gets the glass capsule macOS 26 puts around a custom toolbar item — a custom
/// `.principal` view did both wrong: it outgrew the toolbar on a long path and sat in a capsule around the
/// state pill's own capsule.
@MainActor
enum ThreadTitle {
    static func title(_ session: ThreadSession) -> String {
        session.profile.name
    }

    /// `@acme · …/api/auth-refresh`; the scope alone when the cwd is the home folder.
    static func subtitle(_ session: ThreadSession, scope: ScopeState?) -> String {
        [scope?.name, abbreviatedDirectory(currentDirectory(session))].compactMap { $0 }.joined(separator: " · ")
    }

    static func currentDirectory(_ session: ThreadSession) -> String {
        session.reportedDirectory ?? session.record.cwd
    }

    /// The last two path components (`…/acme/auth-refresh`); `~` for home and home-relative when shorter.
    static func abbreviatedDirectory(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let relative = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return relative }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
