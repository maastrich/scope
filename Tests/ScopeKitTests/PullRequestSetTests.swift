import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite struct PullRequestSetTests {
    static func link(_ number: Int, repo: String? = nil, state: String? = nil, owner: String = "o") -> LinkedPullRequest {
        LinkedPullRequest(number: number, url: URL(string: "https://github.com/\(owner)/\(repo ?? "r")/pull/\(number)")!,
                          title: "PR \(number)", state: state, repo: repo)
    }

    @Test func theOrderFollowsTheRepositoriesThenTheNumbers() {
        let links = [Self.link(43, repo: "api"), Self.link(7, repo: "web"), Self.link(41, repo: "api"), Self.link(2)]
        let ordered = PullRequestSet.ordered(links, repoOrder: ["api", "web"])
        // A link without a repository sorts last; the order never depends on the states.
        #expect(ordered.map(\.number) == [41, 43, 7, 2])
        #expect(PullRequestSet.ordered(links, repoOrder: ["web", "api"]).map(\.number) == [7, 41, 43, 2])
        // Ties on repository and number keep their place.
        let twins = [Self.link(5, repo: "api", owner: "a"), Self.link(5, repo: "api", owner: "b")]
        #expect(PullRequestSet.ordered(twins, repoOrder: ["api"]).map(\.url) == twins.map(\.url))
    }

    @Test func thePrimaryIsTheFirstOpenThenTheFirstMerged() {
        let merged = Self.link(7, repo: "web", state: "merged")
        let open = Self.link(43, repo: "api", state: "open")
        let closed = Self.link(41, repo: "api", state: "closed")
        #expect(PullRequestSet.primary([closed, merged, open])?.number == 43)
        #expect(PullRequestSet.primary([closed, merged])?.number == 7)
        #expect(PullRequestSet.primary([closed])?.number == 41)
        #expect(PullRequestSet.primary([]) == nil)
        // A link never refreshed is open: it was made of an open pull request.
        #expect(PullRequestSet.primary([merged, Self.link(9)])?.number == 9)
    }

    @Test func theStateOfTheSetIsOpenWhileAnyIs() {
        #expect(PullRequestSet.aggregateState([]) == nil)
        #expect(PullRequestSet.aggregateState(["merged", "open"]) == "open")
        #expect(PullRequestSet.aggregateState(["merged", nil]) == "open")
        #expect(PullRequestSet.aggregateState(["merged", "closed"]) == "merged")
        #expect(PullRequestSet.aggregateState(["closed", "closed"]) == "closed")
        #expect(PullRequestSet.aggregateState(["merged"]) == "merged")
        #expect(!PullRequestSet.isSettled([]))
        #expect(!PullRequestSet.isSettled(["merged", "open"]))
        #expect(PullRequestSet.isSettled(["merged", "closed"]))
    }

    @Test func mergingReplacesAKnownURLInPlaceAndKeepsItsRepository() {
        let first = Self.link(41, repo: "api", state: "open")
        let second = Self.link(7, repo: "web", state: "open")
        var refreshed = Self.link(41, repo: "api", state: "merged")
        refreshed.repo = nil
        refreshed.title = "PR 41 renamed"
        let merged = PullRequestSet.merging([first, second], with: [refreshed, Self.link(43, repo: "api")])
        #expect(merged.map(\.number) == [41, 7, 43])
        #expect(merged[0].state == "merged" && merged[0].title == "PR 41 renamed" && merged[0].repo == "api")
    }

    @Test func mergingKeepsAKnownHeadCommitALinkDoesNotCarry() {
        var known = Self.link(41, repo: "api", state: "open")
        known.headRefOid = "abc123"
        let merged = PullRequestSet.merging([known], with: [Self.link(41, repo: "api", state: "merged")])
        #expect(merged[0].headRefOid == "abc123" && merged[0].state == "merged")
        var moved = Self.link(41, repo: "api", state: "merged")
        moved.headRefOid = "def456"
        #expect(PullRequestSet.merging([known], with: [moved])[0].headRefOid == "def456")
    }

    @Test func theCaptionCountsWhatMattersMostFirst() {
        func facts(_ number: Int, _ state: PullRequest.State = .open, checks: PullRequest.Checks = .none,
                   mergeable: PullRequest.Mergeable = .unknown, draft: Bool = false) -> PullRequestFacts {
            PullRequestFacts(number: number, isDraft: draft, checks: checks, mergeable: mergeable, state: state)
        }
        #expect(PullRequestSet.caption([]) == nil)
        #expect(PullRequestSet.caption([facts(1, checks: .failing)]) == nil)
        #expect(PullRequestSet.caption([facts(7, .merged, checks: .passing), facts(41, checks: .failing)]) == "2 PRs · 1 merged · 1 checks failing")
        #expect(PullRequestSet.caption([facts(1, checks: .passing), facts(2, checks: .pending), facts(3, checks: .passing, mergeable: .conflicting),
                                        facts(4, draft: true), facts(5), facts(6, .closed)])
                == "6 PRs · 1 conflicting · 1 checks running · 1 checks passed · 1 draft · 1 open · 1 closed")
    }

    @Test func aRecordKeepsItsLinksInOrderAndDerivesTheirState() throws {
        let record = TaskRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/w", scopeSlug: "acme", name: "T", slug: "t",
                                branch: "feat/t", root: "/w/t",
                                repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/s/api", branch: "feat/t"),
                                        TaskRepo(repoRelativePath: "web", sandboxPath: "/s/web", branch: "feat/t")],
                                pullRequests: [Self.link(7, repo: "web", state: "merged"), Self.link(41, repo: "api", state: "open")])
        #expect(record.pullRequests.map(\.number) == [41, 7])
        #expect(record.primaryPullRequest?.number == 41)
        #expect(record.pullRequestState == "open")
        let data = try JSONEncoder().encode(record)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["pullRequests"] as? [Any])?.count == 2 && json["pullRequest"] == nil)
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: data)
        #expect(decoded.pullRequests == record.pullRequests)
        #expect(record.snapshot.pullRequests.map(\.repo) == ["api", "web"])
        #expect(record.snapshot.pullRequest?.number == 41)
    }

    @Test func aHistoryLineWithOnePullRequestStillReads() throws {
        let legacy = """
        {"id":"a","name":"A","slug":"a","scopeID":"s","scopeSlug":"s","scopeName":"S","branch":"b","repos":["api"],
         "createdAt":0,"createdByAgent":false,
         "pullRequest":{"number":4,"url":"https://github.com/o/r/pull/4","title":"Four","state":"merged"}}
        """
        let snapshot = try JSONDecoder().decode(TaskSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.pullRequests.map(\.number) == [4] && snapshot.pullRequestState == "merged")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        #expect(encoded["pullRequest"] != nil && (encoded["pullRequests"] as? [Any])?.count == 1)
    }
}

@Suite struct VisitedBranchesTests {
    @Test func branchesComeOffCheckoutLinesNewestFirstWithoutTheCurrentOrMain() {
        let reflog = [
            "checkout: moving from docs/multi to feat/multi",
            "commit: docs: cache study",
            "checkout: moving from feat/multi to docs/multi",
            "commit: api: cache endpoint",
            "checkout: moving from main to feat/multi",
            "checkout: moving from 1a2b3c4d5e6f to main",
            "reset: moving to HEAD",
        ]
        #expect(VisitedBranches.parse(reflogSubjects: reflog, current: "feat/multi", excluding: ["main"]) == ["docs/multi"])
        #expect(VisitedBranches.parse(reflogSubjects: reflog, current: "docs/multi", excluding: ["main"]) == ["feat/multi"])
        #expect(VisitedBranches.parse(reflogSubjects: reflog, current: nil) == ["feat/multi", "docs/multi", "main"])
        let many = (1...10).map { "checkout: moving from b\($0) to b\($0 + 1)" }
        #expect(VisitedBranches.parse(reflogSubjects: many, current: "b2", limit: 3).count == 3)
        #expect(VisitedBranches.parse(reflogSubjects: [], current: "x").isEmpty)
    }

    @Test func theTallyCountsWhatCountsAndCaptionsIt() {
        let runs = [PullRequestCheck(name: "build", state: .passing), PullRequestCheck(name: "test", state: .failing),
                    PullRequestCheck(name: "lint", state: .pending), PullRequestCheck(name: "label", state: .skipped),
                    PullRequestCheck(name: "docs", state: .passing)]
        let tally = PullRequestSet.tally(runs)
        #expect(tally == .init(passed: 2, failed: 1, pending: 1, skipped: 1))
        #expect(tally.total == 4 && tally.caption == "✗ 1 / 4" && tally.checks == .failing)
        #expect(PullRequestSet.CheckTally(passed: 1, pending: 1).caption == "● 1 / 2")
        #expect(PullRequestSet.CheckTally(passed: 4).caption == "✓ 4 / 4")
        #expect(PullRequestSet.CheckTally(skipped: 2).caption == nil)
        #expect(PullRequestSet.tally([]).checks == .none)
    }

    @Test func theVerdictTakesTheMostBlockingFact() {
        typealias Set_ = PullRequestSet
        let green = Set_.CheckTally(passed: 4)
        #expect(Set_.verdict(state: .merged, isDraft: false, mergeable: .conflicting, tally: green, review: .none) == .merged)
        #expect(Set_.verdict(state: .open, isDraft: true, mergeable: .conflicting, tally: green, review: .none) == .conflicting)
        #expect(Set_.verdict(state: .open, isDraft: true, mergeable: .mergeable, tally: .init(passed: 3, failed: 2), review: .approved) == .checksFailing(2))
        #expect(Set_.verdict(state: .open, isDraft: false, mergeable: .mergeable, tally: green, review: .changesRequested) == .changesRequested)
        #expect(Set_.verdict(state: .open, isDraft: true, mergeable: .mergeable, tally: green, review: .approved) == .draft)
        #expect(Set_.verdict(state: .open, isDraft: false, mergeable: .mergeable, tally: .init(passed: 1, pending: 3), review: .approved) == .checksRunning)
        #expect(Set_.verdict(state: .open, isDraft: false, mergeable: .mergeable, tally: green, review: .reviewRequired) == .reviewNeeded)
        #expect(Set_.verdict(state: .open, isDraft: false, mergeable: .mergeable, tally: green, review: .approved) == .ready)
        // Nothing read yet: no checks, mergeability unknown.
        #expect(Set_.verdict(state: .open, isDraft: false, mergeable: .unknown, tally: .init(), review: .none) == .open)
        #expect(Set_.Verdict.checksFailing(1).label == "1 check failing")
        #expect(Set_.Verdict.ready.asksTheAgent && !Set_.Verdict.draft.asksTheAgent)
    }
}
