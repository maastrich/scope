import AppKit
import ScopeCore
import UserNotifications

/// macOS notifications about threads (spec §4.7). Authorization is requested the first time something is
/// worth posting, never at launch. One notification per thread (`identifier` = thread id), so repeats
/// replace each other; `clear` removes it once the user looks at the thread or it exits.
@MainActor
final class ThreadNotifier {
    nonisolated static let category = "thread"
    nonisolated static let goToThreadAction = "goToThread"
    nonisolated static let seeDeltaAction = "seeDelta"

    private var categoryRegistered = false

    /// Posts `content` for `threadID` when the app is not frontmost. Silently drops when the user denied.
    func post(_ content: ThreadNotificationContent, threadID: ThreadID) {
        registerCategoryIfNeeded()
        let center = UNUserNotificationCenter.current()
        let request = Self.request(content, threadID: threadID)
        // The async form keeps `center` and `request` on this actor. The completion-handler pair handed both to
        // a `@Sendable` closure instead, and neither type is `Sendable`.
        Task { @MainActor in
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
                try await center.add(request)
            } catch {
                Log.threads.warning("notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clear(threadID: ThreadID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [threadID.rawValue])
        center.removeDeliveredNotifications(withIdentifiers: [threadID.rawValue])
    }

    private static func request(_ content: ThreadNotificationContent, threadID: ThreadID) -> UNNotificationRequest {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.categoryIdentifier = category
        body.threadIdentifier = threadID.rawValue
        body.sound = .default
        return UNNotificationRequest(identifier: threadID.rawValue, content: body, trigger: nil)
    }

    private func registerCategoryIfNeeded() {
        guard !categoryRegistered else { return }
        categoryRegistered = true
        let goTo = UNNotificationAction(identifier: Self.goToThreadAction, title: "Go to Thread", options: [.foreground])
        let delta = UNNotificationAction(identifier: Self.seeDeltaAction, title: "See Delta", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.category, actions: [goTo, delta], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
