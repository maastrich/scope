import Foundation
import ScopeAdapters
import ScopeCore

/// Keeping each thread's `ThreadActivity` across restarts: read back when the session is wired, written when a turn
/// closes or a reply arrives, removed with the record.
extension AppModel {
    /// Hooks `session` to the activity store and reads back what it saved last time. Events can land before the
    /// read does, so the saved activity is folded under them rather than over them.
    func wireActivity(_ session: ThreadSession, carrying previous: ThreadActivity? = nil) {
        let store = env.threadActivity
        session.onActivityChanged = { session in
            let id = session.id, activity = session.activity
            Task { await store.save(activity, for: id) }
        }
        if let previous {
            session.setActivity(session.activity.restoring(previous))
            return
        }
        let id = session.id
        Task { [weak session] in
            guard let saved = await store.load(id), let session else { return }
            session.setActivity(session.activity.restoring(saved))
        }
    }

    /// The thread is closed for good: its activity goes with its record.
    func forgetActivity(_ id: ThreadID) async {
        await env.threadActivity.delete(id)
    }
}
