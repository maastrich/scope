import Foundation
import Testing
@testable import ScopeAssist
import ScopeCore
@testable import ScopeGit
import ScopeTasks

/// Cancelled checks GitHub replaced by a newer run of the same workflow are followed, not read as failures.
@Suite struct CheckResolutionTests {
    /// A real rollup, anonymised (owner, repository, branch): the head commit of a pull request whose
    /// `Linear ms-testers` workflow ran once per event (opened, edited, labelled) under `cancel-in-progress`. Job
    /// 126048119791 was cancelled for run 41673616722, which passed; an *older* run (job 126044814491) passed too,
    /// and a later one (126054833978). Every id is kept: their order is what the resolution reads.
    static let rollup = """
    {"number": 42, "title": "feat: footfall mutations", "author": {"login": "someone"}, "headRefName": "feat/footfall",
     "headRefOid": "51f73a6964254e1415bc1a2e29695189c574b701", "baseRefName": "main", "isDraft": false,
     "reviewDecision": "", "updatedAt": "2026-11-03T16:40:40Z", "url": "https://github.com/acme/agents/pull/42",
     "isCrossRepository": false, "headRepositoryOwner": {"login": "acme"}, "mergeable": "MERGEABLE", "state": "OPEN",
     "statusCheckRollup": [
      {"__typename": "CheckRun", "workflowName": "Linear ms-testers", "name": "LinearMsTesters", "status": "COMPLETED", "conclusion": "CANCELLED",
       "startedAt": "2026-11-03T16:22:55Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41673589963/job/126048119791"},
      {"__typename": "CheckRun", "workflowName": "Check Moby Brief", "name": "check", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:17:35Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41672650292/job/126044815503"},
      {"__typename": "CheckRun", "workflowName": "Check maximus", "name": "check", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:17:34Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41672650618/job/126044817580"},
      {"__typename": "CheckRun", "workflowName": "Linear", "name": "Linear", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:17:28Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41672650305/job/126044814747"},
      {"__typename": "CheckRun", "workflowName": "Linear", "name": "Linear", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:23:09Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41673589888/job/126048119769"},
      {"__typename": "CheckRun", "workflowName": "Linear ms-testers", "name": "LinearMsTesters", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:17:32Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41672650189/job/126044814491"},
      {"__typename": "CheckRun", "workflowName": "Linear ms-testers", "name": "LinearMsTesters", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:23:10Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41673616722/job/126048218335"},
      {"__typename": "CheckRun", "workflowName": "Linear ms-testers", "name": "LinearMsTesters", "status": "COMPLETED", "conclusion": "SUCCESS",
       "startedAt": "2026-11-03T16:34:06Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41675477589/job/126054833978"},
      {"__typename": "CheckRun", "workflowName": "Validate-YAML", "name": "notify", "status": "COMPLETED", "conclusion": "SKIPPED",
       "startedAt": "2026-11-03T16:17:42Z", "detailsUrl": "https://github.com/acme/agents/actions/runs/41672650313/job/126044981061"}
     ]}
    """

    /// The annotations GitHub wrote on that cancelled job (`gh api …/check-runs/126048119791/annotations`).
    static let concurrencyAnnotations = """
    [{"path": ".github", "start_line": 1, "end_line": 1, "annotation_level": "failure", "title": "",
      "message": "Canceling since a higher priority waiting request for Linear ms-testers-feat/footfall exists", "raw_details": ""}]
    """

    static func pr(_ json: String = rollup) throws -> PullRequest {
        try PullRequest.parseOne(json: Data(json.utf8))
    }

    /// A rollup of `checks` on pull request 7 of `acme/api`, each `(workflow, name, conclusion or status, run, job)`.
    static func rollup(_ checks: [(String?, String, String, Int, Int)]) throws -> PullRequest {
        let entries = checks.map { workflow, name, state, run, job in
            let done = ["SUCCESS", "FAILURE", "CANCELLED", "SKIPPED", "TIMED_OUT"].contains(state)
            return """
            {"__typename": "CheckRun", \(workflow.map { "\"workflowName\": \"\($0)\"," } ?? "") "name": "\(name)",
             "status": "\(done ? "COMPLETED" : state)", "conclusion": \(done ? "\"\(state)\"" : "null"),
             "detailsUrl": "https://github.com/acme/api/actions/runs/\(run)/job/\(job)"}
            """
        }
        return try pr("""
        {"number": 7, "title": "t", "headRefName": "b", "headRefOid": "abc", "baseRefName": "main",
         "url": "https://github.com/acme/api/pull/7", "statusCheckRollup": [\(entries.joined(separator: ","))]}
        """)
    }

    // MARK: Replaced, the successor in the rollup

    @Test func theRealRollupFollowsTheRunThatReplacedTheCancelledJob() throws {
        let pr = try Self.pr()
        #expect(pr.checks == .passing)
        #expect(!pr.checkRuns.contains { $0.state == .cancelled || $0.state == .failing })
        // The cancelled row is gone; every other row stays, the successor with its own `?pr=` link.
        #expect(pr.checkRuns.count == 8)
        let testers = pr.checkRuns.filter { $0.name == "LinearMsTesters" }
        #expect(testers.count == 3)
        #expect(testers.contains { $0.detailsURL?.absoluteString == "https://github.com/acme/agents/actions/runs/41673616722/job/126048218335?pr=42" })
        #expect(CheckResolution.unexplainedCancellations(pr.checkRuns).isEmpty)
    }

    @Test func replacedByARunStillGoingIsPending() throws {
        let pr = try Self.rollup([("CI", "test", "SUCCESS", 1, 10), ("CI", "build", "CANCELLED", 1, 11), ("CI", "build", "IN_PROGRESS", 2, 20)])
        #expect(pr.checks == .pending)
        #expect(pr.checkRuns.map(\.state) == [.passing, .pending])
        #expect(pr.checkRuns.last?.actionsJob == ActionsJob(run: 2, job: 20))
    }

    @Test func replacedByARunThatPassedIsGreen() throws {
        let pr = try Self.rollup([("CI", "build", "CANCELLED", 1, 11), ("CI", "build", "SUCCESS", 2, 20)])
        #expect(pr.checks == .passing)
        #expect(pr.checkRuns.map(\.state) == [.passing])
    }

    @Test func replacedByARunThatFailedIsAFailureOfThatRun() throws {
        let pr = try Self.rollup([("CI", "build", "CANCELLED", 1, 11), ("CI", "build", "FAILURE", 2, 20)])
        #expect(pr.checks == .failing)
        #expect(pr.checkRuns.count == 1)
        #expect(pr.checkRuns.first?.actionsJob == ActionsJob(run: 2, job: 20))
    }

    @Test func onlyANewerRunReplaces() throws {
        // The success came first; the cancellation after it is not covered by it.
        let pr = try Self.rollup([("CI", "build", "SUCCESS", 1, 10), ("CI", "build", "CANCELLED", 2, 20)])
        #expect(pr.checks == .cancelled)
        #expect(pr.checkRuns.map(\.state) == [.passing, .cancelled])
    }

    @Test func aChainOfCancellationsEndsOnTheNewestRun() throws {
        let pr = try Self.rollup([("CI", "build", "CANCELLED", 1, 10), ("CI", "build", "CANCELLED", 2, 20), ("CI", "build", "QUEUED", 3, 30)])
        #expect(pr.checks == .pending)
        #expect(pr.checkRuns.map { $0.actionsJob?.run } == [3])
    }

    @Test func aRerunAttemptOfTheSameRunReplacesByItsNewerJob() throws {
        let pr = try Self.rollup([("CI", "build", "CANCELLED", 5, 50), ("CI", "build", "SUCCESS", 5, 51)])
        #expect(pr.checks == .passing)
    }

    // MARK: Workflows and matrices

    @Test func aSameNamedJobOfAnotherWorkflowIsNoSuccessor() throws {
        let pr = try Self.rollup([("Lint", "check", "CANCELLED", 1, 10), ("Test", "check", "SUCCESS", 2, 20)])
        #expect(pr.checks == .cancelled)
        #expect(pr.checkRuns.map(\.title) == ["Lint / check", "Test / check"])
    }

    @Test func mixedWorkflowsResolveEachOnTheirOwn() throws {
        let pr = try Self.rollup([
            ("Lint", "lint", "CANCELLED", 1, 10), ("Test", "unit", "CANCELLED", 2, 20),
            ("Lint", "lint", "SUCCESS", 3, 30), ("Test", "unit", "IN_PROGRESS", 4, 40), ("Docs", "build", "SUCCESS", 5, 50),
        ])
        #expect(pr.checks == .pending)
        #expect(pr.checkRuns.map(\.title) == ["Lint / lint", "Test / unit", "Docs / build"])
    }

    @Test func matrixLegsAreFollowedLegByLeg() throws {
        let pr = try Self.rollup([
            ("CI", "test (macos-15, 18)", "CANCELLED", 1, 10), ("CI", "test (macos-15, 20)", "CANCELLED", 1, 11),
            ("CI", "test (macos-15, 18)", "SUCCESS", 2, 20),
        ])
        // Leg 18 was replaced; leg 20's new job is not in the rollup yet, so it stays to be explained.
        #expect(pr.checkRuns.map(\.name) == ["test (macos-15, 20)", "test (macos-15, 18)"])
        #expect(CheckResolution.unexplainedCancellations(pr.checkRuns) == [ActionsJob(run: 1, job: 11)])
    }

    @Test func aMatrixLegStoppedByItsSiblingsFailureIsNeutralAndTheFailureStays() throws {
        let pr = try Self.rollup([("CI", "test (linux)", "FAILURE", 1, 10), ("CI", "test (macos)", "CANCELLED", 1, 11)])
        let annotations = #"[{"message": "The strategy configuration was canceled because \"test.linux\" failed"}]"#
        #expect(try !CheckResolution.isConcurrencyCancellation(annotationsJSON: Data(annotations.utf8)))
        let followed = pr.following(supersededJobs: [])
        #expect(followed.checks == .failing)
        #expect(followed.checkRuns.map(\.state) == [.failing, .cancelled])
    }

    // MARK: Replaced, the successor not visible yet

    @Test func aConcurrencyCancellationWithoutVisibleSuccessorIsPendingNeverFailing() throws {
        let pr = try Self.rollup([("CI", "test", "SUCCESS", 1, 10), ("CI", "build", "CANCELLED", 1, 11)])
        #expect(pr.checks == .cancelled)
        #expect(CheckResolution.unexplainedCancellations(pr.checkRuns) == [ActionsJob(run: 1, job: 11)])
        #expect(try CheckResolution.isConcurrencyCancellation(annotationsJSON: Data(Self.concurrencyAnnotations.utf8)))
        let followed = pr.following(supersededJobs: [11])
        #expect(followed.checks == .pending)
        #expect(followed.checkRuns.last?.state == .pending)
        #expect(followed.checkRuns.last?.awaitingReplacement == true)
        #expect(CheckResolution.unexplainedCancellations(followed.checkRuns).isEmpty)
        // Applying it again changes nothing.
        #expect(followed.following(supersededJobs: [11]) == followed)
    }

    // MARK: Real cancellations

    @Test func aCancellationWithoutSuccessorStaysCancelledNeitherRedNorGreen() throws {
        let pr = try Self.rollup([("CI", "test", "SUCCESS", 1, 10), ("CI", "build", "CANCELLED", 1, 11)])
        let manual = #"[{"message": "The run was canceled by @someone."}, {"message": "The operation was canceled."}]"#
        #expect(try !CheckResolution.isConcurrencyCancellation(annotationsJSON: Data(manual.utf8)))
        #expect(try !CheckResolution.isConcurrencyCancellation(annotationsJSON: Data("[]".utf8)))
        let followed = pr.following(supersededJobs: [])
        #expect(followed.checks == .cancelled)
        #expect(followed.checkRuns.map(\.state) == [.passing, .cancelled])
        // Not ready to merge, not failing: the one-word verdict says what happened.
        let tally = PullRequestSet.tally(followed.checkRuns)
        #expect(tally == .init(passed: 1, cancelled: 1))
        #expect(tally.caption == "⊘ 1 / 2")
        #expect(PullRequestSet.verdict(state: .open, isDraft: false, mergeable: .mergeable, tally: tally, review: .none) == .checksCancelled)
        // The sidebar says the pull request is open, never that its checks failed or passed.
        #expect(PullRequestFacts(number: 7, checks: .cancelled).status == .pullRequestOpen)
    }

    @Test func aTimeoutStaysAFailure() throws {
        let pr = try Self.rollup([("CI", "build", "TIMED_OUT", 1, 11), ("CI", "build", "SUCCESS", 2, 20)])
        #expect(pr.checks == .failing)
    }

    @Test func foldOrder() {
        #expect(CheckResolution.summarize([]) == .none)
        #expect(CheckResolution.summarize([.skipped]) == .passing)
        #expect(CheckResolution.summarize([.passing, .cancelled]) == .cancelled)
        #expect(CheckResolution.summarize([.pending, .cancelled]) == .pending)
        #expect(CheckResolution.summarize([.failing, .pending, .cancelled]) == .failing)
    }

    // MARK: The "Checks failed" trigger

    @Test func aReplacedJobNeverWakesTheThreadButItsSuccessorsFailureDoes() throws {
        let idle = Date(timeIntervalSinceReferenceDate: 0)
        let now = idle.addingTimeInterval(3600)
        let replaced = try Self.rollup([("CI", "build", "CANCELLED", 1, 11), ("CI", "build", "IN_PROGRESS", 2, 20)])
        let failing = replaced.checkRuns.filter { $0.state == .failing }.count
        let pending = replaced.checkRuns.filter { $0.state == .pending }.count
        #expect(failing == 0)
        #expect(!CheckWake.isDue(failing: failing, pending: pending, failingSince: nil, threadIdleSince: idle, now: now))
        // The same head later: the new run failed. The key `ci@<head>` was never used, so it acts.
        let failed = try Self.rollup([("CI", "build", "CANCELLED", 1, 11), ("CI", "build", "FAILURE", 2, 20)])
        let nowFailing = failed.checkRuns.filter { $0.state == .failing }
        #expect(nowFailing.map(\.actionsJob) == [ActionsJob(run: 2, job: 20)])
        #expect(CheckWake.isDue(failing: nowFailing.count, pending: 0, failingSince: now, threadIdleSince: idle, now: now))
        let thread = ThreadID(rawValue: "aaaaaaaaaaaa")!
        let proposal = ActingTriggers.Proposal(trigger: .ciFailed, thread: thread, key: "ci@\(failed.headRefOid ?? "")",
                                               action: .send("go"), cause: "failing")
        #expect(ActingTriggers.decide(proposal, thread: .init(id: thread), preference: .init(enabled: true, hourlyCap: 2),
                                      ledger: .init(), now: now) == .act)
    }
}
