import Foundation
import Testing
@testable import ScopeGit

@Suite struct PullRequestParsingTests {
    private static let sample = """
    [
      {"number": 12, "title": "Fix refresh token", "author": {"login": "alice"}, "headRefName": "feature/x",
       "baseRefName": "main", "isDraft": true, "reviewDecision": "", "statusCheckRollup": [],
       "updatedAt": "2026-09-01T10:00:00Z", "url": "https://github.com/acme/api/pull/12",
       "isCrossRepository": false, "headRepositoryOwner": {"login": "acme"}, "mergeable": "MERGEABLE"},
      {"number": 13, "title": "Approved one", "author": {"login": "bob"}, "headRefName": "feat/approved",
       "baseRefName": "main", "isDraft": false, "reviewDecision": "APPROVED",
       "statusCheckRollup": [
         {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS", "name": "build"},
         {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED", "name": "label"},
         {"__typename": "StatusContext", "state": "SUCCESS", "context": "ci/lint"}
       ],
       "updatedAt": "2026-09-02T10:00:00Z", "url": "https://github.com/acme/api/pull/13",
       "isCrossRepository": false, "headRepositoryOwner": {"login": "acme"}, "mergeable": "CONFLICTING"},
      {"number": 14, "title": "Failing checks", "author": {"login": "app/dependabot"}, "headRefName": "dep/bump",
       "baseRefName": "main", "isDraft": false, "reviewDecision": "CHANGES_REQUESTED",
       "statusCheckRollup": [
         {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
         {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": null},
         {"__typename": "StatusContext", "state": "FAILURE"}
       ],
       "updatedAt": "2026-09-03T10:00:00Z", "url": "https://github.com/acme/api/pull/14",
       "isCrossRepository": false, "headRepositoryOwner": {"login": "acme"}, "mergeable": "UNKNOWN"},
      {"number": 15, "title": "From a fork", "author": {"login": "carol"}, "headRefName": "carol-fix",
       "baseRefName": "develop", "isDraft": false, "reviewDecision": "REVIEW_REQUIRED",
       "statusCheckRollup": [{"__typename": "CheckRun", "status": "QUEUED", "conclusion": null}],
       "updatedAt": "2026-09-04T10:00:00Z", "url": "https://github.com/acme/api/pull/15",
       "isCrossRepository": true, "headRepositoryOwner": {"login": "carol"}}
    ]
    """

    @Test func parsesTheListWithDerivedStates() throws {
        let prs = try PullRequest.parse(json: Data(Self.sample.utf8))
        #expect(prs.map(\.number) == [12, 13, 14, 15])

        let draft = prs[0]
        #expect(draft.isDraft && draft.reviewDecision == .none && draft.checks == .none)
        #expect(draft.author == "alice" && draft.headRefName == "feature/x" && draft.baseRefName == "main")
        #expect(draft.mergeable == .mergeable && draft.headOwner == "acme" && !draft.isCrossRepository)
        #expect(draft.url.absoluteString == "https://github.com/acme/api/pull/12")
        #expect(draft.updatedAt == ISO8601DateFormatter().date(from: "2026-09-01T10:00:00Z"))

        let approved = prs[1]
        #expect(approved.reviewDecision == .approved && approved.checks == .passing && approved.mergeable == .conflicting)

        let failing = prs[2]
        #expect(failing.reviewDecision == .changesRequested && failing.checks == .failing)
        #expect(failing.author == "app/dependabot" && failing.mergeable == .unknown)

        let fork = prs[3]
        #expect(fork.isCrossRepository && fork.headOwner == "carol" && fork.reviewDecision == .reviewRequired)
        #expect(fork.checks == .pending && fork.baseRefName == "develop" && fork.mergeable == .unknown)
    }

    @Test func parsesOneObjectAndToleratesMissingOptionals() throws {
        let json = #"{"number": 7, "title": "Minimal", "headRefName": "h", "baseRefName": "main", "url": "https://github.com/acme/api/pull/7"}"#
        let pr = try PullRequest.parseOne(json: Data(json.utf8))
        #expect(pr.number == 7 && pr.author == "" && !pr.isDraft && pr.checks == .none && pr.headOwner == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) { try PullRequest.parse(json: Data("{".utf8)) }
    }

    @Test func checkSummaryPrecedence() {
        typealias Check = PullRequest.DTO.Check
        #expect(PullRequest.summarize(checks: []) == .none)
        #expect(PullRequest.summarize(checks: [Check(status: "COMPLETED", conclusion: "NEUTRAL", state: nil)]) == .passing)
        #expect(PullRequest.summarize(checks: [Check(status: "COMPLETED", conclusion: "SUCCESS", state: nil), Check(status: "QUEUED", conclusion: nil, state: nil)]) == .pending)
        #expect(PullRequest.summarize(checks: [Check(status: "QUEUED", conclusion: nil, state: nil), Check(status: nil, conclusion: nil, state: "ERROR")]) == .failing)
        #expect(PullRequest.summarize(checks: [Check(status: nil, conclusion: nil, state: "PENDING")]) == .pending)
    }
}
