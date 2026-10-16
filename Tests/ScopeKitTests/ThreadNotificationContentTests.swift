import Testing
@testable import ScopeCore

@Suite struct ThreadNotificationContentTests {
    @Test func titleJoinsDriverScopeAndTask() {
        let content = ThreadNotificationContent.make(event: .inputRequested, driver: "Claude", scope: "acme", task: "auth-refresh")
        #expect(content == ThreadNotificationContent(title: "Claude · acme · auth-refresh", body: "needs your answer"))
        let noTask = ThreadNotificationContent.make(event: .permissionRequested, driver: "Claude", scope: "acme")
        #expect(noTask == ThreadNotificationContent(title: "Claude · acme", body: "asks for a permission"))
        #expect(ThreadNotificationContent.make(event: .turnEnded, driver: "Codex", scope: "s")?.body == "finished its turn")
    }

    @Test func aFailedTurnSaysWhy() {
        #expect(ThreadNotificationContent.make(event: .turnFailed, driver: "Claude", scope: "s", failure: "rate_limit")?.body
                == "stopped on an error: rate limit")
        #expect(ThreadNotificationContent.make(event: .turnFailed, driver: "Claude", scope: "s")?.body == "stopped on an error")
        #expect(ThreadNotificationContent.shouldNotify(event: .turnFailed, appIsActive: false))
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

    // MARK: What the agent said

    @Test func aFinishedTurnQuotesTheOpeningOfItsAnswer() {
        let reply = "## Summary\n\nFixed the **token refresh** in `auth.swift`.\n\n- added a test\n- bumped the cache"
        let content = ThreadNotificationContent.make(event: .turnEnded, driver: "Claude", scope: "acme", said: .reply(reply))
        #expect(content == ThreadNotificationContent(
            title: "Claude · acme", subtitle: "finished its turn",
            body: "Fixed the token refresh in auth.swift. added a test bumped the cache"))
    }

    @Test func aQuestionQuotesTheClosingParagraphOfTheAnswer() {
        let reply = "I looked at both options.\n\nShould I *rename* the table, or keep [the alias](https://x.y)?"
        let content = ThreadNotificationContent.make(event: .inputRequested, driver: "Claude", scope: "s", said: .reply(reply))
        #expect(content?.subtitle == "needs your answer")
        #expect(content?.body == "Should I rename the table, or keep the alias?")
    }

    @Test func aQuestionToolIsQuotedFromItsStart() {
        let content = ThreadNotificationContent.make(event: .inputRequested, driver: "Claude", scope: "s",
                                                     said: .question("Which database?\nSQLite or Postgres?"))
        #expect(content?.body == "Which database? SQLite or Postgres?")
    }

    @Test func permissionsAndFailuresKeepTheirWords() {
        let permission = ThreadNotificationContent.make(event: .permissionRequested, driver: "C", scope: "s", said: .question("May I?"))
        #expect(permission == ThreadNotificationContent(title: "C · s", body: "asks for a permission"))
        let failure = ThreadNotificationContent.make(event: .turnFailed, driver: "C", scope: "s", failure: "overloaded", said: .reply("x"))
        #expect(failure == ThreadNotificationContent(title: "C · s", body: "stopped on an error: overloaded"))
    }

    @Test func nothingReadableFallsBackToTheGenericBody() {
        let content = ThreadNotificationContent.make(event: .turnEnded, driver: "C", scope: "s", said: .reply("```swift\nlet x = 1\n```\n\n---"))
        #expect(content == ThreadNotificationContent(title: "C · s", body: "finished its turn"))
    }

    @Test func excerptDropsCodeBlocksQuotesTablesAndRules() {
        let text = """
            > Note: done
            ```
            secret code
            ```
            | a | b |
            |---|---|
            | 1 | 2 |
            ***
            1. first
            - [x] second
            Compute 2 * 3 with snake_case
            """
        #expect(ThreadNotificationContent.excerpt(text, from: .opening)
                == "Note: done a · b 1 · 2 first second Compute 2 * 3 with snake_case")
    }

    @Test func headingsCountOnlyWhenThereIsNothingElse() {
        #expect(ThreadNotificationContent.excerpt("# All green", from: .opening) == "All green")
        #expect(ThreadNotificationContent.excerpt("# Title\nbody", from: .closing) == "body")
    }

    @Test func excerptIsCappedOnAWordBoundary() {
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let excerpt = ThreadNotificationContent.excerpt(words, from: .opening)!
        #expect(excerpt.count <= ThreadNotificationContent.excerptLimit)
        #expect(excerpt.hasSuffix("word…"))
        let exact = String(repeating: "a", count: 180)
        #expect(ThreadNotificationContent.excerpt(exact, from: .opening) == exact)
        let unbroken = String(repeating: "é", count: 300)
        #expect(ThreadNotificationContent.excerpt(unbroken, from: .opening) == String(repeating: "é", count: 179) + "…")
        #expect(ThreadNotificationContent.excerpt("Done, 👍🏽 " + words, from: .opening)!.hasPrefix("Done, 👍🏽 word"))
    }

    @Test func aShortOpeningTakesTheNextParagraphs() {
        #expect(ThreadNotificationContent.excerpt("Done.\n\nThe build passes.\n\nNext: docs.", from: .opening)
                == "Done. The build passes. Next: docs.")
        #expect(ThreadNotificationContent.excerpt("   \n\n", from: .opening) == nil)
    }
}
