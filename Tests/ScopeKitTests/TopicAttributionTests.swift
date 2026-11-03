import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// Which tasks Scope files together, and under what name (`TopicAttribution`, `TopicName`).
@Suite struct TopicAttributionTests {
    typealias Member = TopicAttribution.Member

    static func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }

    static func task(_ id: String, topic: String? = nil, explicit: Bool = false, parent: String? = nil, issue: String? = nil,
                     prs: [String] = [], heads: Set<String> = [], bases: Set<String> = [], at minute: Double = 0) -> Member {
        Member(id: id, name: id, topic: topic, explicit: explicit, parent: parent, issue: issue, pullRequests: prs,
               heads: heads.isEmpty ? [".|feat/\(id)"] : heads, bases: bases, createdAt: at(minute))
    }

    static func decide(_ members: [Member], extra: [TopicAttribution.Link] = [], refiling: Bool = false) -> [TopicAttribution.Decision] {
        TopicAttribution.decide(members, links: TopicAttribution.strongLinks(members) + extra, refiling: refiling)
    }

    // MARK: Orphans

    @Test func aTaskOnItsOwnGetsNothing() {
        #expect(Self.decide([Self.task("a")]).isEmpty)
    }

    /// Two unrelated tasks of one repository are not a topic: the repository alone is no link.
    @Test func sharingARepositoryIsNoLink() {
        #expect(Self.decide([Self.task("a", at: 0), Self.task("b", at: 1)]).isEmpty)
    }

    // MARK: The topic is born with the sibling

    @Test func aChildAndItsParentGetANewTopicTogether() {
        let decisions = Self.decide([Self.task("parent", at: 0), Self.task("child", parent: "parent", at: 1)])
        #expect(decisions == [.create(tasks: ["parent", "child"], name: nil)])
    }

    @Test func aChildJoinsItsParentsTopic() {
        let decisions = Self.decide([Self.task("parent", topic: "auth", at: 0), Self.task("child", parent: "parent", at: 1)])
        #expect(decisions == [.file(tasks: ["child"], under: "auth")])
    }

    @Test func stackedPullRequestsAreOneTopic() {
        let lower = Self.task("lower", heads: [".|feat/lower"], at: 0)
        let upper = Self.task("upper", heads: [".|feat/upper"], bases: [".|feat/lower"], at: 1)
        #expect(TopicAttribution.strongLinks([lower, upper]) == [.init("lower", "upper", kind: .stack)])
        #expect(Self.decide([lower, upper]) == [.create(tasks: ["lower", "upper"], name: nil)])
    }

    /// The same base branch name in two repositories is two stacks, not one.
    @Test func aStackIsPerRepository() {
        let api = Self.task("api", heads: ["api|feat/x"], at: 0)
        let web = Self.task("web", heads: ["web|feat/y"], bases: ["web|feat/x"], at: 1)
        #expect(TopicAttribution.strongLinks([api, web]).isEmpty)
    }

    /// Both based on main is not a stack: main is no task's head.
    @Test func twoPullRequestsOnMainAreNoStack() {
        let a = Self.task("a", bases: [".|main"], at: 0)
        let b = Self.task("b", bases: [".|main"], at: 1)
        #expect(TopicAttribution.strongLinks([a, b]).isEmpty)
    }

    @Test func theSameIssueOrPullRequestLinks() {
        let issue = "https://github.com/acme/api/issues/12"
        let pr = "https://github.com/acme/api/pull/40"
        #expect(TopicAttribution.strongLinks([Self.task("a", issue: issue), Self.task("b", issue: issue)]).map(\.kind) == [.issue])
        #expect(TopicAttribution.strongLinks([Self.task("a", prs: [pr]), Self.task("b", prs: [pr])]).map(\.kind) == [.pullRequest])
    }

    /// The weak link comes from the assistant, with its name for what the two share.
    @Test func aBriefLinkCarriesTheAssistantsName() {
        let decisions = Self.decide([Self.task("a", at: 0), Self.task("b", at: 1)],
                                    extra: [.init("a", "b", kind: .brief, name: " \"Auth rework.\" ")])
        #expect(decisions == [.create(tasks: ["a", "b"], name: "Auth rework")])
    }

    @Test func aBriefLinkToATaskWithATopicFilesUnderIt() {
        let decisions = Self.decide([Self.task("a", topic: "billing", at: 0), Self.task("b", at: 1)],
                                    extra: [.init("a", "b", kind: .brief, name: "payments")])
        #expect(decisions == [.file(tasks: ["b"], under: "billing")])
    }

    /// A chain is one piece of work: a grandchild lands with its grandparent.
    @Test func linksAreTransitive() {
        let decisions = Self.decide([Self.task("a", at: 0), Self.task("b", parent: "a", at: 1), Self.task("c", parent: "b", at: 2)])
        #expect(decisions == [.create(tasks: ["a", "b", "c"], name: nil)])
    }

    @Test func twoGroupsAreDecidedApart() {
        let decisions = Self.decide([
            Self.task("a", at: 0), Self.task("b", parent: "a", at: 1),
            Self.task("c", topic: "docs", at: 2), Self.task("d", parent: "c", at: 3),
            Self.task("lone", at: 4),
        ])
        #expect(decisions == [.create(tasks: ["a", "b"], name: nil), .file(tasks: ["d"], under: "docs")])
    }

    /// Run again on its own result, it decides nothing: refreshes never churn.
    @Test func itIsIdempotent() {
        let decisions = Self.decide([Self.task("a", topic: "auth", at: 0), Self.task("b", topic: "Auth", parent: "a", at: 1)])
        #expect(decisions.isEmpty)
    }

    @Test func aParentOutsideTheOpenTasksIsNoLink() {
        #expect(Self.decide([Self.task("child", parent: "archived")]).isEmpty)
    }

    // MARK: Explicit choices win

    /// A topic someone gave is never replaced, and a task they took out of any topic stays out.
    @Test func anExplicitTopicIsNeverMoved() {
        let decisions = Self.decide([Self.task("a", topic: "auth", at: 0),
                                     Self.task("b", topic: "billing", explicit: true, parent: "a", at: 1)])
        #expect(decisions.isEmpty)
    }

    @Test func anExplicitNoneStaysOutAndLeavesTheOtherAlone() {
        let decisions = Self.decide([Self.task("a", explicit: true, at: 0), Self.task("b", parent: "a", at: 1)])
        #expect(decisions.isEmpty)
    }

    /// An explicit topic is the group's anchor: a new task joins it rather than the automatic one.
    @Test func anExplicitTopicWinsOverAnAutomaticOne() {
        let members = [
            Self.task("a", topic: "login", at: 0),
            Self.task("b", topic: "auth rework", explicit: true, parent: "a", at: 1),
            Self.task("c", parent: "b", at: 2),
        ]
        #expect(Self.decide(members) == [.file(tasks: ["c"], under: "auth rework")])
        #expect(Self.decide(members, refiling: true) == [.file(tasks: ["a", "c"], under: "auth rework")])
    }

    /// A task Scope already filed stays with the sibling it was filed with, whatever links appear later.
    @Test func anAutomaticTopicIsKeptOutsideTheMigration() {
        let members = [Self.task("a", topic: "x", at: 0), Self.task("b", topic: "y", parent: "a", at: 1)]
        #expect(Self.decide(members).isEmpty)
    }

    @Test func theMostSharedTopicWinsThenTheOldest() {
        let shared = Self.decide([
            Self.task("a", topic: "x", at: 0), Self.task("b", topic: "y", parent: "a", at: 1), Self.task("c", topic: "y", parent: "a", at: 2),
        ], refiling: true)
        #expect(shared == [.file(tasks: ["a"], under: "y")])
        let tie = Self.decide([Self.task("a", topic: "x", at: 0), Self.task("b", topic: "y", parent: "a", at: 1)], refiling: true)
        #expect(tie == [.file(tasks: ["b"], under: "x")])
        let fresh = Self.decide([Self.task("a", topic: "x", at: 0), Self.task("b", topic: "x", at: 1), Self.task("c", parent: "b", at: 2),
                                 Self.task("d", topic: "y", parent: "c", at: 3)])
        #expect(fresh == [.file(tasks: ["c"], under: "x")])
    }

    /// The migration never splits a topic two open tasks share, even for a stronger link elsewhere.
    @Test func theMigrationDoesNotSplitASharedTopic() {
        let members = [
            Self.task("a", topic: "geo", at: 0), Self.task("b", topic: "geo", at: 1),
            Self.task("c", topic: "agents", parent: "a", at: 2), Self.task("d", topic: "agents", at: 3),
            Self.task("e", topic: "lcm", parent: "c", at: 4),
        ]
        // a and c stay with their siblings; only e, alone under its topic, moves (under the oldest of the two).
        #expect(Self.decide(members, refiling: true) == [.file(tasks: ["e"], under: "geo")])
    }

    // MARK: Migration

    @Test func theRegroupTreatsOldTopicsAsMovableButNotExplicitOnes() {
        func record(_ id: String, topic: String?, source: TopicSource?, parent: String? = nil, minute: Double) -> TaskRecord {
            var record = TaskRecord(id: TaskID(rawValue: id)!, scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/tmp", scopeSlug: "acme",
                                    name: id, slug: id, branch: "feat/\(id)", root: "/tmp/\(id)", createdAt: Self.at(minute),
                                    topic: topic, parentTask: parent.flatMap(TaskID.init(rawValue:)))
            record.topicSource = source
            return record
        }
        let parent = record("aaaaaaaaaaaa", topic: "Split the login", source: nil, minute: 0)
        let child = record("bbbbbbbbbbbb", topic: "auth", source: nil, parent: "aaaaaaaaaaaa", minute: 1)
        let pinned = record("cccccccccccc", topic: "mine", source: .explicit, parent: "aaaaaaaaaaaa", minute: 2)
        // Before the rules every topic counts as explicit: creation-time attribution leaves them all alone.
        let members = [parent, child, pinned].map(TopicAttribution.Member.init)
        #expect(TopicAttribution.decide(members, links: TopicAttribution.strongLinks(members)).isEmpty)
        // The opt-in regroup moves the old ones under the explicit topic, and never the explicit one.
        #expect(TopicAttribution.regroup([parent, child, pinned]) == [.file(tasks: ["aaaaaaaaaaaa", "bbbbbbbbbbbb"], under: "mine")])
    }

    @Test func aRecordsBranchesAndPullRequestsAreItsHeadsAndBases() {
        var record = TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/tmp", scopeSlug: "acme", name: "n", slug: "s",
                                branch: "feat/upper", root: "/tmp/s",
                                repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/tmp/s/api", branch: "feat/upper")])
        record.pullRequests = [LinkedPullRequest(number: 2, url: URL(string: "https://github.com/acme/api/pull/2")!, title: "t",
                                                 repo: "api", headRefName: "feat/upper", baseRefName: "feat/lower")]
        let member = TopicAttribution.Member(record)
        #expect(member.heads == ["api|feat/upper"])
        #expect(member.bases == ["api|feat/lower"])
        #expect(!member.explicit)
    }
}

@Suite struct TopicNameTests {
    @Test func aNameIsOneToThreeWordsWithoutQuotes() {
        #expect(TopicName.clean("  “Auth token refresh rework”. ") == "Auth token refresh")
        #expect(TopicName.clean("none") == nil)
        #expect(TopicName.clean(" ... ") == nil)
        #expect(TopicName.clean(nil) == nil)
    }

    @Test func spellingsOfOneSubjectAreOneTopic() {
        #expect(TopicName.canonical("Authentication") == TopicName.canonical("auth"))
        #expect(TopicName.canonical("Sidebar topics") == TopicName.canonical("topic sidebar"))
        #expect(TopicName.canonical("Les réglages") == TopicName.canonical("settings"))
        #expect(TopicName.canonical("docs") == TopicName.canonical("Documentation"))
        #expect(TopicName.canonical("auth") != TopicName.canonical("billing"))
    }

    /// An existing topic that fits is reused rather than a near-duplicate.
    @Test func anExistingSpellingIsReused() {
        #expect(TopicName.reuse("authentication", among: ["Billing", "Auth"]) == "Auth")
        #expect(TopicName.reuse("payments", among: ["Billing", "Auth"]) == "payments")
    }

    /// Without the assistant: what the tasks share, never the first one's whole title.
    @Test func theFallbackNamesWhatTheTasksShare() {
        #expect(TopicName.fallback(names: ["Refresh auth tokens", "Log out of auth everywhere"]) == "auth")
        #expect(TopicName.fallback(names: ["Speed up the sidebar", "Tighten sidebar margins"]) == "sidebar")
        #expect(TopicName.fallback(names: ["Refresh tokens", "Log out"], branches: ["feat/auth-refresh", "feat/auth-logout"]) == "auth")
        #expect(TopicName.fallback(names: ["Rework the topics attribution", "Unrelated thing"]) == "rework topics")
        #expect(TopicName.fallback(names: []) == nil)
    }
}
