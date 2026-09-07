import Testing
@testable import ScopeCore

@Suite struct ThreadNotificationContentTests {
    @Test func titleJoinsDriverScopeAndTask() {
        let content = ThreadNotificationContent.make(event: .inputRequested, driver: "Claude", scope: "acme", task: "auth-refresh")
        #expect(content == ThreadNotificationContent(title: "Claude · acme · auth-refresh", body: "needs your input"))
        let noTask = ThreadNotificationContent.make(event: .permissionRequested, driver: "Claude", scope: "acme")
        #expect(noTask == ThreadNotificationContent(title: "Claude · acme", body: "asks for a permission"))
        #expect(ThreadNotificationContent.make(event: .turnEnded, driver: "Codex", scope: "s")?.body == "finished its turn")
    }

    @Test func silentEventsProduceNothing() {
        for event in [ThreadStateEvent.turnStarted, .threadEnded, .processExited] {
            #expect(ThreadNotificationContent.make(event: event, driver: "d", scope: "s") == nil)
            #expect(!ThreadNotificationContent.shouldNotify(event: event, appIsActive: false))
        }
    }

    @Test func frontmostAppNeverNotifies() {
        #expect(ThreadNotificationContent.shouldNotify(event: .inputRequested, appIsActive: false))
        #expect(!ThreadNotificationContent.shouldNotify(event: .inputRequested, appIsActive: true))
    }
}
