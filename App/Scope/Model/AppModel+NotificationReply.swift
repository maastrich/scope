import Foundation
import ScopeControl
import ScopeCore

/// Reply on a thread's notification: the answer is typed into the thread the way `scope thread send` types it, and
/// the app stays in the background.
extension AppModel {
    func reply(_ text: String, to id: ThreadID) {
        // An empty answer would be a bare ↩, which picks whatever option a question tool has highlighted.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            guard let service = env.controls.service else { return }
            // `.user`: the owner typing, so no sender envelope, and the same not-running and resident handling as
            // the command line.
            let result = await service.perform(.threadSend(ThreadSendParams(thread: id.rawValue, text: text)),
                                               from: .user, caller: ControlCaller(client: "scope-notification"),
                                               progress: { _ in })
            switch result {
            case .success:
                notifier.clear(threadID: id)
            case .failure(let error):
                Log.threads.notice("notification reply to \(id.rawValue, privacy: .public) failed: \(error.message, privacy: .public)")
                // The banner is the only place the user is looking: say it there, in place of the one answered.
                notifier.post(ThreadNotificationContent(title: "Reply not sent", body: error.message), threadID: id)
            }
        }
    }
}
