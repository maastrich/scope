import Foundation

/// What a macOS notification about a thread says (spec §4.7). Pure: the app decides *whether* to post
/// (it is not frontmost) and *how* (UserNotifications); this type only decides *what* for a given event.
public struct ThreadNotificationContent: Equatable, Sendable {
    /// `"<driver> · <scope>"` or `"<driver> · <scope> · <task>"`.
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// The content for `event`, or `nil` when the event is not one the user is told about
    /// (only `inputRequested`, `permissionRequested`, `turnEnded` and `turnFailed` notify). `failure` is the
    /// driver's error code for `turnFailed` (`rate_limit`, …), shown in words.
    public static func make(event: ThreadStateEvent, driver: String, scope: String, task: String? = nil,
                            failure: String? = nil) -> ThreadNotificationContent? {
        let body: String
        switch event {
        case .inputRequested: body = "needs your answer"
        case .permissionRequested: body = "asks for a permission"
        case .turnEnded: body = "finished its turn"
        case .turnFailed: body = "stopped on an error" + (failureDescription(failure).map { ": \($0)" } ?? "")
        case .turnStarted, .threadEnded, .processExited: return nil
        }
        let parts = [driver, scope] + (task.map { [$0] } ?? [])
        return ThreadNotificationContent(title: parts.joined(separator: " · "), body: body)
    }

    /// `true` when a notification is worth posting: the event notifies and the app is not frontmost.
    public static func shouldNotify(event: ThreadStateEvent, appIsActive: Bool) -> Bool {
        guard !appIsActive else { return false }
        switch event {
        case .inputRequested, .permissionRequested, .turnEnded, .turnFailed: return true
        case .turnStarted, .threadEnded, .processExited: return false
        }
    }

    /// `rate_limit` → `rate limit`; `nil` for no code at all.
    public static func failureDescription(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return code.replacingOccurrences(of: "_", with: " ")
    }
}
