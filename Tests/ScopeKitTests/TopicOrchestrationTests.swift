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
            .init(task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: before)]),
            .init(task: "b", pullRequests: [Self.pr(2, "merged", mergedAt: after), Self.pr(3, "open")]),
        ], since: Self.opened)
        #expect(milestones == [.merged(task: "b", number: 2, url: "https://github.com/acme/api/pull/2")])
    }

    @Test func theTopicIsDeliveredWhenEveryTaskHasLanded() {
        let after = Self.opened.addingTimeInterval(60)
        let milestones = TopicOrchestration.milestones([
            .init(task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: Self.opened.addingTimeInterval(-60))]),
            .init(task: "b", pullRequests: [Self.pr(2, "merged", mergedAt: after), Self.pr(3, "closed")]),
        ], since: Self.opened)
        #expect(milestones.last == .delivered(tasks: ["a", "b"]))
        #expect(milestones.last?.key == "delivered:a,b")
    }

    /// A task without a pull request has not landed; nor has a topic whose last merge predates the orchestrator.
    @Test func aTaskWithoutPullRequestHoldsTheTopicOpen() {
        let after = Self.opened.addingTimeInterval(60)
        #expect(!TopicOrchestration.milestones([
            .init(task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: after)]), .init(task: "b", pullRequests: []),
        ], since: Self.opened).contains(.delivered(tasks: ["a", "b"])))
        #expect(TopicOrchestration.milestones([
            .init(task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: Self.opened.addingTimeInterval(-1))]),
        ], since: Self.opened).isEmpty)
    }

    /// A task dropped without a pull request holds nothing up once archived; open, it does.
    @Test func anArchivedTaskWithoutPullRequestIsDropped() {
        let after = Self.opened.addingTimeInterval(60)
        let members: [TopicOrchestration.Member] = [
            .init(task: "a", pullRequests: [Self.pr(1, "merged", mergedAt: after)], archived: true),
            .init(task: "b", pullRequests: [], archived: true),
        ]
        #expect(TopicOrchestration.milestones(members, since: Self.opened).last == .delivered(tasks: ["a"]))
    }

    /// The ledger acts once per key: a merge is one notice, whatever the refreshes that see it.
    @Test func eachMilestoneHasAStableKey() {
        let merged = TopicOrchestration.Milestone.merged(task: "a", number: 2, url: "https://x/pull/2")
        #expect(merged.key == "merged:https://x/pull/2")
        #expect(TopicOrchestration.Milestone.delivered(tasks: ["b", "a"]).key == "delivered:a,b")
    }

    // MARK: Putting away

    static let quiet = TopicOrchestration.quietBeforeClosing

    static func standing(openTasks: Int = 0, working: Bool = false, waitingOnUser: Bool = false, pendingMessages: Bool = false,
                         unread: Bool = false, watched: Bool = false, idleFor: TimeInterval = quiet) -> TopicOrchestration.Standing {
        .init(openTasks: openTasks, working: working, waitingOnUser: waitingOnUser, pendingMessages: pendingMessages,
              unread: unread, watched: watched, lastActivity: opened.addingTimeInterval(-idleFor))
    }

    @Test func itGoesOnceItsTopicIsEmptyAndTheUserIsDoneWithIt() {
        #expect(TopicOrchestration.hold(Self.standing(), now: Self.opened) == nil)
        #expect(TopicOrchestration.hold(Self.standing(openTasks: 1), now: Self.opened) == .openTasks)
    }

    @Test func workAndOwedAnswersHoldIt() {
        #expect(TopicOrchestration.hold(Self.standing(working: true), now: Self.opened) == .working)
        #expect(TopicOrchestration.hold(Self.standing(waitingOnUser: true), now: Self.opened) == .waitingOnUser)
        #expect(TopicOrchestration.hold(Self.standing(pendingMessages: true), now: Self.opened) == .pendingMessages)
    }

    /// The incident: the last task archived, the orchestrator answered Scope's last notice, and was closed within a
    /// second of that answer. The turn that just ended holds it — unread, and too recent — however long ago a person typed.
    @Test func theReportOfTheLastMergeIsNotClosedUnderTheReader() {
        #expect(TopicOrchestration.hold(Self.standing(unread: true, idleFor: 0.6), now: Self.opened) == .unread)
        #expect(TopicOrchestration.hold(Self.standing(idleFor: 0.6), now: Self.opened) == .recentActivity)
        // Unread stays unread: a day later it is still there to be read.
        #expect(TopicOrchestration.hold(Self.standing(unread: true, idleFor: 86_400), now: Self.opened) == .unread)
    }

    /// The user goes on talking to it after the last archive: neither while it is on screen nor between two messages.
    @Test func aConversationWithTheUserHoldsIt() {
        #expect(TopicOrchestration.hold(Self.standing(watched: true, idleFor: 86_400), now: Self.opened) == .watched)
        #expect(TopicOrchestration.hold(Self.standing(idleFor: Self.quiet - 1), now: Self.opened) == .recentActivity)
        #expect(TopicOrchestration.hold(Self.standing(idleFor: Self.quiet), now: Self.opened) == nil)
    }

    /// One that waited on the user at the last archive is looked at again later: answered, read and left alone, it goes.
    @Test func oneThatWaitedGoesOnceAnsweredAndLeftAlone() {
        var standing = Self.standing(waitingOnUser: true, idleFor: 3 * Self.quiet)
        #expect(TopicOrchestration.hold(standing, now: Self.opened) == .waitingOnUser)
        standing.waitingOnUser = false
        standing.lastActivity = Self.opened
        #expect(TopicOrchestration.hold(standing, now: Self.opened.addingTimeInterval(60)) == .recentActivity)
        #expect(TopicOrchestration.hold(standing, now: Self.opened.addingTimeInterval(Self.quiet)) == nil)
    }

    // MARK: Closed orchestrators

    static let scope = ScopeID(rawValue: "s1")

    static func orchestrator(_ topic: String?, resumeID: String? = "session-1", scope: ScopeID = scope) -> ThreadRecord {
        var record = ThreadRecord(scopeID: scope, scopeRoot: "/acme", driverID: "claude-code", title: "Topic · \(topic ?? "-")",
                                  cwd: "/acme", cwdKind: .scopeRoot, createdAt: opened, topic: topic)
        record.resumeID = resumeID
        return record
    }

    @Test func aClosedOrchestratorIsFoundAgainByItsTopic() {
        var retired = RetiredOrchestrators()
        let record = Self.orchestrator("Auth rework")
        retired.keep(record)
        #expect(retired.record(topic: "auth  rework", scope: Self.scope) == record)
        #expect(retired.record(topic: "auth rework", scope: ScopeID(rawValue: "other")) == nil)
        #expect(retired.remove(topic: "AUTH REWORK", scope: Self.scope) == record)
        #expect(retired.records.isEmpty)
    }

    @Test func onlyWhatCanBeResumedIsKept() {
        var retired = RetiredOrchestrators()
        retired.keep(Self.orchestrator("auth", resumeID: nil))
        retired.keep(Self.orchestrator(nil))
        #expect(retired.records.isEmpty)
    }

    @Test func theLatestCloseOfATopicReplacesTheOlder() {
        var retired = RetiredOrchestrators()
        retired.keep(Self.orchestrator("auth", resumeID: "old"))
        retired.keep(Self.orchestrator("billing"))
        retired.keep(Self.orchestrator("Auth", resumeID: "new"))
        #expect(retired.records.count == 2)
        #expect(retired.record(topic: "auth", scope: Self.scope)?.resumeID == "new")
    }

    @Test func theOldestGoFirstPastTheLimit() {
        var retired = RetiredOrchestrators()
        for index in 0...RetiredOrchestrators.limit { retired.keep(Self.orchestrator("topic \(index)")) }
        #expect(retired.records.count == RetiredOrchestrators.limit)
        #expect(retired.record(topic: "topic 0", scope: Self.scope) == nil)
        #expect(retired.record(topic: "topic \(RetiredOrchestrators.limit)", scope: Self.scope) != nil)
    }

    @Test func aRenamedTopicStillFindsItsClosedOrchestrator() {
        var retired = RetiredOrchestrators()
        retired.keep(Self.orchestrator("auth"))
        retired.rename(topic: "Auth", to: "Login", title: "Topic · Login", scope: Self.scope)
        #expect(retired.record(topic: "auth", scope: Self.scope) == nil)
        #expect(retired.record(topic: "login", scope: Self.scope)?.title == "Topic · Login")
    }

    @Test func theListSurvivesARestart() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-retired-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RetiredOrchestrators.load(home: home).records.isEmpty)
        var retired = RetiredOrchestrators()
        retired.keep(Self.orchestrator("auth"))
        try retired.save(home: home)
        #expect(RetiredOrchestrators.load(home: home) == retired)
        #expect(RetiredOrchestrators.load(home: home).record(topic: "auth", scope: Self.scope)?.resumeID == "session-1")
    }

    @Test func theBriefSaysTheConversationComesBack() {
        let brief = TopicOrchestration.brief(topic: "auth", scope: "acme", tasks: [])
        #expect(brief.contains("resumes this conversation"))
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
