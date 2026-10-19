import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// `ReturnDigest`: what the "since your last visit" strip says, and `ScopeVisits`, the baseline it is measured from.
@Suite struct ReturnDigestTests {
    typealias Thread = ReturnDigest.ThreadFacts
    typealias Task = ReturnDigest.TaskFacts

    static let since = Date(timeIntervalSince1970: 10_000)
    static func after(_ seconds: TimeInterval) -> Date { since.addingTimeInterval(seconds) }
    static func before(_ seconds: TimeInterval) -> Date { since.addingTimeInterval(-seconds) }

    static let a = ThreadID(rawValue: "aaaaaaaaaaaa")!
    static let b = ThreadID(rawValue: "bbbbbbbbbbbb")!
    static let t1 = TaskID(rawValue: "111111111111")!
    static let t2 = TaskID(rawValue: "222222222222")!
    static let t3 = TaskID(rawValue: "333333333333")!

    static func pr(_ number: Int = 7, _ state: PullRequest.State = .open, _ checks: PullRequest.Checks? = nil) -> PullRequestSnapshot {
        PullRequestSnapshot(number: number, url: URL(string: "https://github.com/o/r/pull/\(number)")!, state: state, checks: checks)
    }

    static func digest(threads: [Thread] = [], tasks: [Task] = [], seen: [TaskID: PullRequestSnapshot] = [:],
                       seenAll: [TaskID: [PullRequestSnapshot]] = [:]) -> ReturnDigest? {
        ReturnDigest.make(since: since, threads: threads, tasks: tasks, seen: seen.mapValues { [$0] }.merging(seenAll) { $1 })
    }

    // MARK: Nothing to say

    @Test func nothingAfterTheVisitIsNoDigest() {
        let digest = Self.digest(
            threads: [Thread(id: Self.a, finishedTurns: [Self.before(60)], failedTurns: [Self.before(5)],
                             waitingSince: Self.before(30))],
            tasks: [Task(id: Self.t1, name: "api-cache", pullRequests: [Self.pr(7, .open, .failing)])],
            seen: [Self.t1: Self.pr(7, .open, .failing)])
        #expect(digest == nil)
    }

    @Test func noThreadsNoTasksIsNoDigest() {
        #expect(Self.digest() == nil)
    }

    // MARK: Turns and questions

    @Test func turnsAreCountedAcrossThreadsAndOpenTheLatest() throws {
        let digest = try #require(Self.digest(threads: [
            Thread(id: Self.a, finishedTurns: [Self.before(10), Self.after(10), Self.after(300)]),
            Thread(id: Self.b, finishedTurns: [Self.after(20)]),
        ]))
        #expect(digest.since == Self.since)
        #expect(digest.fragments == [.init(kind: .turnsFinished, count: 3, text: "3 turns finished", target: .thread(Self.a))])
    }

    @Test func oneTurnIsSingular() throws {
        let digest = try #require(Self.digest(threads: [Thread(id: Self.b, failedTurns: [Self.after(1)])]))
        #expect(digest.fragments.map(\.text) == ["1 turn failed"])
    }

    @Test func aQuestionAskedBeforeTheVisitIsNotNews() throws {
        let digest = try #require(Self.digest(threads: [
            Thread(id: Self.a, waitingSince: Self.before(1)),
            Thread(id: Self.b, waitingSince: Self.after(40)),
        ]))
        #expect(digest.fragments == [.init(kind: .questions, count: 1, text: "1 question for you", target: .thread(Self.b))])
    }

    @Test func questionsOpenTheOneWaitingLongest() throws {
        let digest = try #require(Self.digest(threads: [
            Thread(id: Self.a, waitingSince: Self.after(90)),
            Thread(id: Self.b, waitingSince: Self.after(40)),
        ]))
        #expect(digest.fragments.first?.text == "2 questions for you")
        #expect(digest.fragments.first?.target == .thread(Self.b))
    }

    // MARK: Pull requests

    @Test func aMergeIsOpenThenMerged() throws {
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "token-refresh", pullRequests: [Self.pr(7, .merged)])],
                                              seen: [Self.t1: Self.pr(7, .open, .passing)]))
        #expect(digest.fragments == [.init(kind: .merged, count: 1, text: "PR merged on token-refresh", target: .task(Self.t1))])
    }

    @Test func aMergedTaskAlreadyArchivedOpensThePullRequest() throws {
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "token-refresh", isArchived: true,
                                                          pullRequests: [Self.pr(7, .merged)])],
                                              seen: [Self.t1: Self.pr(7, .open)]))
        #expect(digest.fragments.first?.target == .url(URL(string: "https://github.com/o/r/pull/7")!))
    }

    @Test func aPullRequestMergedBeforeTheVisitIsNotNews() {
        #expect(Self.digest(tasks: [Task(id: Self.t1, name: "x", isArchived: true, pullRequests: [Self.pr(7, .merged)])],
                            seen: [:]) == nil)
        #expect(Self.digest(tasks: [Task(id: Self.t1, name: "x", pullRequests: [Self.pr(7, .merged)])],
                            seen: [Self.t1: Self.pr(7, .merged)]) == nil)
    }

    @Test func checksFailingOnlyWhenTheyWereNotAlready() throws {
        let digest = try #require(Self.digest(
            tasks: [Task(id: Self.t1, name: "api-cache", pullRequests: [Self.pr(7, .open, .failing)]),
                    Task(id: Self.t2, name: "old-failure", pullRequests: [Self.pr(8, .open, .failing)])],
            seen: [Self.t1: Self.pr(7, .open, .pending), Self.t2: Self.pr(8, .open, .failing)]))
        #expect(digest.fragments == [.init(kind: .checksFailing, count: 1, text: "checks failing on api-cache", target: .task(Self.t1))])
    }

    @Test func checksUnknownThenPassingIsNotNews() {
        #expect(Self.digest(tasks: [Task(id: Self.t1, name: "x", pullRequests: [Self.pr(7, .open, .passing)])],
                            seen: [Self.t1: Self.pr(7, .open, nil)]) == nil)
    }

    @Test func checksTurningGreen() throws {
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "x", pullRequests: [Self.pr(7, .open, .passing)])],
                                              seen: [Self.t1: Self.pr(7, .open, .pending)]))
        #expect(digest.fragments.map(\.text) == ["checks passing on x"])
    }

    @Test func aNewPullRequestIsOpened() throws {
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "x", pullRequests: [Self.pr(9)])]))
        #expect(digest.fragments.map(\.kind) == [.opened])
        #expect(digest.fragments.first?.text == "PR opened on x")
    }

    @Test func anotherNumberIsANewPullRequest() throws {
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "x", pullRequests: [Self.pr(9, .open, .failing)])],
                                              seen: [Self.t1: Self.pr(7, .closed, .failing)]))
        #expect(digest.fragments.map(\.kind) == [.checksFailing, .opened])
    }

    @Test func severalTasksCollapseIntoACount() throws {
        let digest = try #require(Self.digest(
            tasks: [Task(id: Self.t2, name: "b-task", pullRequests: [Self.pr(2, .merged)]),
                    Task(id: Self.t1, name: "a-task", pullRequests: [Self.pr(1, .merged)])],
            seen: [Self.t1: Self.pr(1), Self.t2: Self.pr(2)]))
        #expect(digest.fragments == [.init(kind: .merged, count: 2, text: "PRs merged on 2 tasks", target: .task(Self.t1))])
    }

    // MARK: Order and cap

    @Test func whatWaitsOnTheOwnerComesFirst() throws {
        let digest = try #require(Self.digest(
            threads: [Thread(id: Self.a, finishedTurns: [Self.after(1), Self.after(2)], waitingSince: Self.after(3))],
            tasks: [Task(id: Self.t1, name: "token-refresh", pullRequests: [Self.pr(1, .merged)]),
                    Task(id: Self.t2, name: "api-cache", pullRequests: [Self.pr(2, .open, .failing)])],
            seen: [Self.t1: Self.pr(1), Self.t2: Self.pr(2, .open, .passing)]))
        #expect(digest.fragments.map(\.text) == ["1 question for you", "checks failing on api-cache",
                                                 "PR merged on token-refresh", "2 turns finished"])
        #expect(digest.overflow == 0)
    }

    @Test func pastTheLimitTheRestIsCounted() throws {
        let digest = try #require(Self.digest(
            threads: [Thread(id: Self.a, finishedTurns: [Self.after(1)], failedTurns: [Self.after(2)], waitingSince: Self.after(3))],
            tasks: [Task(id: Self.t1, name: "m", pullRequests: [Self.pr(1, .merged)]),
                    Task(id: Self.t2, name: "f", pullRequests: [Self.pr(2, .open, .failing)]),
                    Task(id: Self.t3, name: "c", pullRequests: [Self.pr(3, .closed)])],
            seen: [Self.t1: Self.pr(1), Self.t2: Self.pr(2, .open, .passing), Self.t3: Self.pr(3)]))
        #expect(digest.fragments.count == ReturnDigest.fragmentLimit)
        #expect(digest.fragments.map(\.kind) == [.questions, .checksFailing, .turnsFailed, .merged])
        #expect(digest.overflow == 2)
    }

    // MARK: Visits file

    @Test func visitsRoundTripThroughTheFile() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "visits-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ScopeVisitStore(home: home)
        #expect(store.load() == ScopeVisits())

        let scope = ScopeID.generate(), gone = ScopeID.generate()
        var visits = ScopeVisits()
        visits[scope] = .init(lastSeen: Self.since, pullRequests: [Self.t1: [Self.pr(7, .open, .failing)]])
        visits[gone] = .init(lastSeen: Self.since)
        visits.retain([scope])
        store.save(visits)

        let loaded = store.load()
        #expect(loaded == visits)
        #expect(loaded[gone] == nil)
        #expect(loaded[scope]?.seenPullRequests == [Self.t1: [Self.pr(7, .open, .failing)]])
    }

    @Test func anotherVersionReadsAsNoVisits() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "visits-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ScopeVisitStore(home: home)
        try Data(#"{"version": 99, "scopes": {}}"#.utf8).write(to: store.url)
        #expect(store.load() == ScopeVisits())
    }

    // MARK: Several pull requests

    @Test func eachPullRequestOfATaskIsComparedOnItsOwn() throws {
        let api = Self.pr(41, .open, .failing), web = Self.pr(7, .merged, .passing), docs = Self.pr(43, .open, .passing)
        let before = [Self.pr(41, .open, .passing), Self.pr(7, .open, .passing)]
        let digest = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "cache", pullRequests: [api, docs, web])],
                                              seenAll: [Self.t1: before]))
        // Red on #41, merged #7, new #43 — three fragments for one task, the task counted once in each.
        #expect(digest.fragments.map(\.kind) == [.checksFailing, .merged, .opened])
        #expect(digest.fragments.map(\.count) == [1, 1, 1])
        #expect(digest.fragments.map(\.text) == ["checks failing on cache", "PR merged on cache", "PR opened on cache"])
        #expect(digest.fragments.allSatisfy { $0.target == .task(Self.t1) })
        // Archived meanwhile: each fragment opens the pull request that moved.
        let gone = try #require(Self.digest(tasks: [Task(id: Self.t1, name: "cache", isArchived: true, pullRequests: [api, web])],
                                            seenAll: [Self.t1: before]))
        #expect(gone.fragments.map(\.target) == [.url(api.url), .url(web.url)])
    }
}
