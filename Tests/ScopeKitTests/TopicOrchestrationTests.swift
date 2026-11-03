import Foundation
import Testing
import ScopeCore
@testable import ScopeControl
@testable import ScopeTasks

/// A topic's orchestrator: what it is told, when it hears from Scope, when it goes (`TopicOrchestration`).
@Suite struct TopicOrchestrationTests {
    static let opened = Date(timeIntervalSince1970: 1_800_000_000)

    static func pr(_ number: Int, _ state: String?, mergedAt: Date? = nil) -> LinkedPullRequest {
        LinkedPullRequest(number: number, url: URL(string: "https://github.com/acme/api/pull/\(number)")!, title: "t",
                          state: state, mergedAt: mergedAt)
    }

    @Test func theBriefNamesTheToolsAndTheTasks() {
        let brief = TopicOrchestration.brief(topic: "auth", scope: "acme", tasks: [
            .init(slug: "refresh", name: "Refresh tokens", state: "working", branch: "feat/refresh",
                  pullRequests: ["#12 open, checks passing"], brief: "Refresh\n\ntokens early", threads: ["3f9a2c17be04"]),
        ])
        #expect(brief.contains("`scope topic show \"auth\"`"))
        #expect(brief.contains("`scope task new \"<brief>\" --topic \"auth\"`"))
        #expect(brief.contains("do not poll"))
        #expect(brief.contains("- Refresh tokens (refresh) — working, branch feat/refresh"))
        #expect(brief.contains("  threads: 3f9a2c17be04"))
        #expect(brief.contains("  brief: Refresh tokens early"))
    }

    @Test func theReportCountsOpenAndArchived() {
        let report = TopicOrchestration.report(topic: "auth", tasks: [
            .init(slug: "a", name: "A", state: "idle", branch: "a"),
            .init(slug: "b", name: "B", state: "done", branch: "b", pullRequests: ["#3 merged"], archived: true),
        ])
        #expect(report.hasPrefix("Topic “auth”: 1 open task, 1 archived"))
        #expect(report.hasSuffix("Archived: B (b, #3 merged)"))
        #expect(!report.contains("- B"))
    }

    /// Only what happened after it was opened: opening it on an old topic does not replay every merge.
    @Test func aMergeAfterOpeningIsAMilestoneAndAnOlderOneIsNot() {
        let before = Self.opened.addingTimeInterval(-60)
        let after = Self.opened.addingTimeInterval(60)
        let milestones = TopicOrchestration.milestones([
            (task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: before)]),
            (task: "b", pullRequests: [Self.pr(2, "merged", mergedAt: after), Self.pr(3, "open")]),
        ], since: Self.opened)
        #expect(milestones == [.merged(task: "b", number: 2, url: "https://github.com/acme/api/pull/2")])
    }

    @Test func theTopicIsDeliveredWhenEveryTaskHasLanded() {
        let after = Self.opened.addingTimeInterval(60)
        let milestones = TopicOrchestration.milestones([
            (task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: Self.opened.addingTimeInterval(-60))]),
            (task: "b", pullRequests: [Self.pr(2, "merged", mergedAt: after), Self.pr(3, "closed")]),
        ], since: Self.opened)
        #expect(milestones.last == .delivered(tasks: ["a", "b"]))
        #expect(milestones.last?.key == "delivered:a,b")
    }

    /// A task without a pull request has not landed; nor has a topic whose last merge predates the orchestrator.
    @Test func aTaskWithoutPullRequestHoldsTheTopicOpen() {
        let after = Self.opened.addingTimeInterval(60)
        #expect(!TopicOrchestration.milestones([
            (task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: after)]), (task: "b", pullRequests: []),
        ], since: Self.opened).contains(.delivered(tasks: ["a", "b"])))
        #expect(TopicOrchestration.milestones([
            (task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: Self.opened.addingTimeInterval(-1))]),
        ], since: Self.opened).isEmpty)
    }

    /// The ledger acts once per key: a merge is one notice, whatever the refreshes that see it.
    @Test func eachMilestoneHasAStableKey() {
        let merged = TopicOrchestration.Milestone.merged(task: "a", number: 2, url: "https://x/pull/2")
        #expect(merged.key == "merged:https://x/pull/2")
        #expect(TopicOrchestration.Milestone.delivered(tasks: ["b", "a"]).key == "delivered:a,b")
    }

    @Test func itClosesWithTheLastOpenTask() {
        #expect(TopicOrchestration.shouldClose(openTasks: 0))
        #expect(!TopicOrchestration.shouldClose(openTasks: 1))
    }

    @Test func theTopicTriggerIsOnWithACap() {
        let preference = ActingTriggerPreferences()[.topic]
        #expect(preference.enabled && preference.hourlyCap == 3)
        #expect(ActingTrigger.topic.rawValue == "topic")
    }
}

@Suite struct TopicOrchestratorRecordTests {
    static let base = #"{"version":1,"id":"3f9a2c17be04","scopeID":"acme","driverID":"claude","cwd":"/tmp""#

    /// Filed under its topic, never among the loose threads.
    @Test func anOrchestratorIsPlacedUnderItsTopic() throws {
        let record = try JSONDecoder().decode(ThreadRecord.self, from: Data((Self.base + #","topic":"Auth  Rework"}"#).utf8))
        #expect(record.topic == "Auth  Rework")
        let placement = ThreadPlacement(record)
        #expect(placement.topicKey == "auth rework")
        #expect(!placement.isLoose)
        let roundTrip = try JSONDecoder().decode(ThreadRecord.self, from: try JSONEncoder().encode(record))
        #expect(roundTrip.topic == record.topic)
    }

    @Test func anOlderRecordHasNoTopic() throws {
        let record = try JSONDecoder().decode(ThreadRecord.self, from: Data((Self.base + "}").utf8))
        #expect(record.topic == nil && ThreadPlacement(record).isLoose)
    }

    @Test func theCommandLineAndTheMCPToolShowATopic() throws {
        guard case .call(let call, _) = try ScopeCLI.parse(["topic", "show", "auth rework", "--scope", "acme"]) else {
            Issue.record("that is a call")
            return
        }
        #expect(call == .topicShow(TopicShowParams(topic: "auth rework", scope: "acme")))
        guard case .call(let bare, _) = try ScopeCLI.parse(["topic", "show"]) else { return }
        #expect(bare == .topicShow(TopicShowParams()))
        #expect(throws: (any Error).self) { try ScopeCLI.parse(["topic", "show", "a", "b"]) }
        #expect(MCPBridge.call(tool: "scope_topic_show", arguments: Data(#"{"topic":"auth"}"#.utf8))
                == .success(.topicShow(TopicShowParams(topic: "auth"))))
        #expect(MCPBridge.tools.first { $0.name == "scope_topic_show" }?.readOnly == true)
        #expect(!ControlMethod.topicShow.isMutating)
        let request = ControlRequest(id: "abcd1234", caller: ControlCaller(client: "scope-cli/1"),
                                     call: .topicShow(TopicShowParams(topic: "auth")))
        #expect(try ControlRequest.decode(try request.encoded()).get() == request)
    }
}
