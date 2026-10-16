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

    /// `@acme › auth-refresh › claude`: where the thread sits, the same path the inspector's Base header starts
    /// with, so the two sides of the window name their subject the same way.
    static func path(scope: String?, task: String?, thread: String) -> String {
        // A thread is named after where it runs — its task, or its scope — so the last step often repeats the one
        // before it; said once is enough.
        var steps: [String] = []
        for step in [scope, task, thread].compactMap({ $0 }) where step != steps.last { steps.append(step) }
        return steps.joined(separator: " › ")
    }

    /// `Claude Code · …/api/auth-refresh`: what runs, and where — the line under the path. While the agent works or
    /// waits, what it is doing takes the place of where (`Claude Code · Editing App.swift`); a line that would need a
    /// clock (`Finished · 3m ago`) does not, the window title has none.
    static func detail(_ session: ThreadSession) -> String {
        if let headline = session.activityHeadline, headline.since == nil {
            return "\(runs(session)) · \(headline.text)"
        }
        return "\(runs(session)) · \(abbreviatedDirectory(currentDirectory(session)))"
    }

    /// `Claude Code (claude-fable-5-1)`: the driver, and the model when one was chosen for the thread.
    static func runs(_ session: ThreadSession) -> String {
        guard let model = session.record.model else { return session.profile.name }
        return "\(session.profile.name) (\(model))"
    }

    /// `@acme · auth-refresh · …/api/auth-refresh`: the scope, the task that owns the thread when one does, the
    /// directory. The task is here because a maximized thread has neither sidebar nor inspector to say it.
    static func subtitle(_ session: ThreadSession, scope: ScopeState?, task: String? = nil) -> String {
        [scope?.name, task, abbreviatedDirectory(currentDirectory(session))].compactMap { $0 }.joined(separator: " · ")
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
