import AppKit
import ScopeCore
import UserNotifications

/// macOS notifications about threads (spec §4.7). Authorization is requested the first time something is
/// worth posting, never at launch. One notification per thread (`identifier` = thread id), so repeats
/// replace each other; `clear` removes it once the user looks at the thread or it exits. Reply types an answer into
/// the thread without bringing the app up (`AppModel.reply(_:to:)`).
@MainActor
final class ThreadNotifier {
    nonisolated static let category = "thread"
    /// A finished turn the assistant read as blocking: the same actions, plus *Not blocking*.
    nonisolated static let triagedCategory = "thread-triaged"
    nonisolated static let goToThreadAction = "goToThread"
    nonisolated static let seeDeltaAction = "seeDelta"
    nonisolated static let replyAction = "reply"
    nonisolated static let notBlockingAction = "notBlocking"
    /// A permission Scope can answer (`ClaudeDialogAnswer`): Allow and Deny in place of Reply, whose ↩ would pick the
    /// dialog's highlighted *Yes*. Without Allow when the banner cannot show the whole command.
    nonisolated static let permissionCategory = "thread-permission"
    nonisolated static let permissionDenyOnlyCategory = "thread-permission-deny"
    nonisolated static let allowAction = "allow"
    nonisolated static let denyAction = "deny"
    /// `userInfo` key of the request a permission notification is about.
    nonisolated static let requestKey = "request"

    private var categoryRegistered = false

    /// Posts `content` for `threadID` when the app is not frontmost. Silently drops when the user denied. `triaged`
    /// when the assistant's verdict is what let it through (spec §4.10), so the person can say it was wrong.
    func post(_ content: ThreadNotificationContent, threadID: ThreadID, triaged: Bool = false) {
        registerCategoryIfNeeded()
        let center = UNUserNotificationCenter.current()
        let request = Self.request(content, threadID: threadID, triaged: triaged)
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

    /// A permission's notification: `requestID` rides along so the answer goes to that request and no other.
    func post(_ content: ThreadNotificationContent, threadID: ThreadID, permission requestID: String, allows: Bool) {
        registerCategoryIfNeeded()
        let center = UNUserNotificationCenter.current()
        let request = Self.request(content, threadID: threadID, triaged: false,
                                   category: allows ? Self.permissionCategory : Self.permissionDenyOnlyCategory,
                                   userInfo: [Self.requestKey: requestID])
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

    private static func request(_ content: ThreadNotificationContent, threadID: ThreadID, triaged: Bool,
                                category: String? = nil, userInfo: [String: String] = [:]) -> UNNotificationRequest {
        let body = UNMutableNotificationContent()
        body.title = content.title
        if let subtitle = content.subtitle { body.subtitle = subtitle }
        body.body = content.body
        body.categoryIdentifier = category ?? (triaged ? triagedCategory : Self.category)
        body.userInfo = userInfo
        body.threadIdentifier = threadID.rawValue
        body.sound = .default
        return UNNotificationRequest(identifier: threadID.rawValue, content: body, trigger: nil)
    }

    private func registerCategoryIfNeeded() {
        guard !categoryRegistered else { return }
        categoryRegistered = true
        let goTo = UNNotificationAction(identifier: Self.goToThreadAction, title: "Go to Thread", options: [.foreground])
        let delta = UNNotificationAction(identifier: Self.seeDeltaAction, title: "See Changes", options: [.foreground])
        // No `.foreground`: answering from the banner is the point, the app stays where it is.
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Answer the thread")
        let category = UNNotificationCategory(identifier: Self.category, actions: [reply, goTo, delta],
                                              intentIdentifiers: [])
        let notBlocking = UNNotificationAction(identifier: Self.notBlockingAction, title: "Not Blocking", options: [])
        let triaged = UNNotificationCategory(identifier: Self.triagedCategory, actions: [reply, goTo, delta, notBlocking],
                                             intentIdentifiers: [])
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [])
        let permission = UNNotificationCategory(identifier: Self.permissionCategory, actions: [allow, deny, goTo],
                                                intentIdentifiers: [])
        let denyOnly = UNNotificationCategory(identifier: Self.permissionDenyOnlyCategory, actions: [deny, goTo],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, triaged, permission, denyOnly])
    }
}
