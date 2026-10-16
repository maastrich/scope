import Foundation
import Testing
@testable import ScopeAssist

/// The jobs as values: their schemas, their pre-filters, and the ledger that counts the calls.
@Suite struct AssistJobsTests {
    @Test func schemasRenderAsOneObjectWithTypedFields() {
        let text = ThreadDigest.schema.promptText
        #expect(text.hasPrefix("{\n") && text.hasSuffix("\n}"))
        #expect(text.contains("\"stuck\": \"boolean — "))
        #expect(NotificationTriage.schema.promptText.contains("one of \"blockingQuestion\", \"informational\", \"failure\""))
        #expect(TopicPick.schema(topics: ["Auth", "Billing"]).promptText.contains("one of \"Auth\", \"Billing\", \"none\""))
    }

    @Test func aDigestIsReadAsACaptionAndAReason() {
        let digest = ThreadDigest(activity: "  Running   swift test. ", stuck: true, reason: "same\nerror")
        #expect(digest.caption == "Running swift test")
        #expect(digest.stuckReason == "same error")
        #expect(ThreadDigest(activity: "", stuck: false, reason: "noise").caption == nil)
        #expect(ThreadDigest(activity: "x", stuck: false, reason: "noise").stuckReason == nil)
    }

    @Test func onlyAnInformationalTriageStaysQuiet() {
        #expect(!NotificationTriage(kind: .informational).interrupts)
        #expect(NotificationTriage(kind: .blockingQuestion).interrupts)
        #expect(NotificationTriage(kind: .failure).interrupts)
    }

    @Test func aShortReplyOrOneEndingOnAQuestionIsNotFinal() {
        let long = String(repeating: "The work is done and every test passes. ", count: 8)
        #expect(ArchiveHint.replyLooksFinal(long))
        #expect(!ArchiveHint.replyLooksFinal("Done."))
        #expect(!ArchiveHint.replyLooksFinal(long + "\nShould I open the pull request now?"))
    }

    @Test func aTopicPickOnlyCountsWhenItNamesAnExistingTopic() {
        let topics = ["Auth", "Billing"]
        #expect(TopicPick(topic: "auth").validated(against: topics) == "Auth")
        #expect(TopicPick(topic: "none").validated(against: topics) == nil)
        #expect(TopicPick(topic: "Payments").validated(against: topics) == nil)
        #expect(TopicPick(topic: nil).validated(against: topics) == nil)
        #expect(TopicPick.input(brief: "Fix login", topics: topics).hasPrefix("Topics: \"Auth\", \"Billing\""))
    }

    @Test func theFakeAnswersFromItsScriptAndRecordsTheCalls() async throws {
        let fake = FakeAssistModel()
        fake.answer(.threadDigest, with: ThreadDigest(activity: "a", stuck: false))
        fake.answer(.threadDigest, with: ThreadDigest(activity: "b", stuck: true, reason: "r"))
        let first: ThreadDigest = try await fake.classify(instructions: "i", input: "x", schema: ThreadDigest.schema)
        let second: ThreadDigest = try await fake.classify(instructions: "i", input: "y", schema: ThreadDigest.schema)
        let third: ThreadDigest = try await fake.classify(instructions: "i", input: "z", schema: ThreadDigest.schema)
        #expect(first.activity == "a" && second.activity == "b" && third.activity == "b")
        #expect(fake.calls.map(\.input) == ["x", "y", "z"])
        fake.setAvailable(false)
        await #expect(throws: AssistError.unavailable) {
            let _: ThreadDigest = try await fake.classify(instructions: "i", input: "w", schema: ThreadDigest.schema)
        }
    }

    // MARK: Ledger

    @Test func theLedgerCountsPerTierAndStartsOverEachDay() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-assist-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AssistLedgerStore(home: home)
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        await store.count(.onDevice, now: today)
        await store.count(.haiku, now: today)
        let ledger = await store.count(.haiku, now: today)
        #expect(ledger.onDeviceCalls == 1 && ledger.haikuCalls == 2)
        #expect(ledger.calls(for: .haiku) == 2)

        // Read back by another store: the day holds.
        let again = await AssistLedgerStore(home: home).today(now: today)
        #expect(again == ledger)

        let tomorrow = await store.today(now: today.addingTimeInterval(86_400))
        #expect(tomorrow.haikuCalls == 0 && tomorrow.day == AssistLedger.dayKey(today.addingTimeInterval(86_400)))
        let flagged = await store.countFalsePositive(now: today.addingTimeInterval(86_400))
        #expect(flagged.falsePositives == 1)
    }
}
