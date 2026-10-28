import Foundation
import Testing
@testable import ScopeAssist

/// Which review comments wake a task's thread, and when: one wake per batch, Copilot included, the viewer's own
/// summaries, bots and handled threads left out.
@Suite struct ReviewWakeTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func item(_ id: String, _ kind: ReviewWake.Kind, by author: String, _ body: String, ago seconds: TimeInterval,
              state: String? = nil, path: String? = nil, line: Int? = nil, handled: Bool = false) -> ReviewWake.Item {
        .init(id: id, kind: kind, author: author, body: body, at: now.addingTimeInterval(-seconds),
              url: URL(string: "https://github.com/o/r/pull/12#\(id)"), state: state, path: path, line: line, handled: handled)
    }

    @Test func aCopilotReviewIsOneBatchOnceItIsQuiet() throws {
        let items = [
            item("r1", .review, by: "copilot-pull-request-reviewer[bot]", "Copilot reviewed 3 out of 3 changed files", ago: 300, state: "COMMENTED"),
            item("c1", .inline, by: "Copilot", "This leaks the handle.", ago: 299, path: "Sources/A.swift", line: 42),
            item("c2", .inline, by: "Copilot", "Off by one.", ago: 298, path: "Sources/B.swift", line: 7),
        ]
        let batch = try #require(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now))
        #expect(batch.comments.map(\.location) == ["Sources/A.swift:42", "Sources/B.swift:7"])
        #expect(batch.comments.allSatisfy { $0.author == "Copilot" })
        #expect(batch.key == "review@c2")
        // Handed over: the same comments never make a second batch.
        #expect(ReviewWake.batch(items, viewer: "me", handledThrough: batch.newest, now: now) == nil)
    }

    @Test func aBatchStillComingInWaits() {
        let items = [item("c1", .inline, by: "alice", "Rename this.", ago: 300, path: "a", line: 1),
                     item("c2", .inline, by: "alice", "And this.", ago: 30, path: "a", line: 2)]
        #expect(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now) == nil)
        #expect(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now.addingTimeInterval(90))?.comments.count == 2)
    }

    @Test func theViewersOwnSummariesAndBotsAreIgnoredButTheirLineCommentsCount() {
        let items = [
            item("p1", .conversation, by: "me", "Done: fixed the tests.", ago: 500),
            item("r1", .review, by: "me", "LGTM", ago: 500, state: "COMMENTED"),
            item("p2", .conversation, by: "vercel[bot]", "Preview ready", ago: 500),
            item("p3", .conversation, by: "github-actions", "Coverage 80%", ago: 500),
            item("r2", .review, by: "bob", "", ago: 500, state: "APPROVED"),
        ]
        #expect(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now) == nil)
        let mine = items + [item("c1", .inline, by: "Me", "Use the helper here.", ago: 400, path: "x.swift", line: 3)]
        #expect(ReviewWake.batch(mine, viewer: "me", handledThrough: nil, now: now)?.comments.map(\.excerpt) == ["Use the helper here."])
    }

    @Test func changesRequestedCountsEvenWithoutWords() throws {
        let items = [item("r1", .review, by: "bob", "", ago: 500, state: "CHANGES_REQUESTED")]
        let batch = try #require(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now))
        #expect(batch.comments.first?.state == "CHANGES_REQUESTED")
        #expect(ActingPrompts.review(pullRequest: 12, comments: batch.comments).contains("bob (changes requested)"))
    }

    @Test func aResolvedOrAnsweredThreadIsHandled() {
        let items = [item("c1", .inline, by: "bob", "Why?", ago: 500, path: "a", line: 1, handled: true)]
        #expect(ReviewWake.batch(items, viewer: "me", handledThrough: nil, now: now) == nil)
    }

    @Test func aCommentOlderThanTheWatermarkIsNotNew() {
        let items = [item("c1", .inline, by: "bob", "Old", ago: 5000, path: "a", line: 1),
                     item("c2", .inline, by: "bob", "New", ago: 500, path: "a", line: 2)]
        let batch = ReviewWake.batch(items, viewer: "me", handledThrough: now.addingTimeInterval(-1000), now: now)
        #expect(batch?.comments.map(\.excerpt) == ["New"])
    }

    // MARK: Checks

    @Test func checksWakeOnlyAnIdleThread() {
        let idle = now.addingTimeInterval(-600)
        #expect(CheckWake.isDue(failing: 1, pending: 0, failingSince: now, threadIdleSince: idle, now: now))
        #expect(!CheckWake.isDue(failing: 0, pending: 0, failingSince: nil, threadIdleSince: idle, now: now))
        #expect(!CheckWake.isDue(failing: 1, pending: 0, failingSince: now, threadIdleSince: now.addingTimeInterval(-30), now: now))
        #expect(!CheckWake.isDue(failing: 1, pending: 0, failingSince: now, threadIdleSince: nil, now: now))
    }

    @Test func checksStillRunningAreWaitedForAWhile() {
        let idle = now.addingTimeInterval(-3600)
        #expect(!CheckWake.isDue(failing: 1, pending: 2, failingSince: now.addingTimeInterval(-60), threadIdleSince: idle, now: now))
        #expect(CheckWake.isDue(failing: 1, pending: 2, failingSince: now.addingTimeInterval(-CheckWake.pendingGrace),
                                threadIdleSince: idle, now: now))
    }
}
