import Foundation
import Testing
@testable import ScopeGit

@Suite struct PullRequestLifecycleTests {
    private static let json = """
    {"number":42,"title":"Cache the catalogue","author":{"login":"ana"},"headRefName":"feat/cache","baseRefName":"main",
     "url":"https://github.com/acme/api/pull/42","mergeable":"CONFLICTING",
     "statusCheckRollup":[
      {"__typename":"CheckRun","name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE",
       "detailsUrl":"https://github.com/acme/api/actions/runs/1234/job/5678"},
      {"__typename":"CheckRun","name":"lint","workflowName":"CI","status":"IN_PROGRESS","conclusion":null,
       "detailsUrl":"https://github.com/acme/api/actions/runs/1234/job/5679"},
      {"__typename":"CheckRun","name":"docs","workflowName":"","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":""},
      {"__typename":"StatusContext","context":"ci/circleci","state":"SUCCESS","targetUrl":"https://circleci.com/gh/acme/api/9"}
     ]}
    """

    @Test func everyCheckOfTheRollupIsKept() throws {
        let pr = try PullRequest.parseOne(json: Data(Self.json.utf8))
        #expect(pr.checks == .failing && pr.mergeable == .conflicting)
        #expect(pr.checkRuns.map(\.title) == ["CI / test", "CI / lint", "docs", "ci/circleci"])
        #expect(pr.checkRuns.map(\.state) == [.failing, .pending, .skipped, .passing])
        #expect(pr.checkRuns[0].actionsJob == ActionsJob(run: 1234, job: 5678))
        #expect(pr.checkRuns[2].detailsURL == nil)
        // A third-party status has no Actions log.
        #expect(pr.checkRuns[3].actionsJob == nil)
    }

    @Test func actionsIDsComeOnlyFromActionsURLs() {
        func job(_ text: String) -> ActionsJob? { ActionsJob(detailsURL: URL(string: text)!) }
        #expect(job("https://github.com/acme/api/actions/runs/1234/job/5678") == ActionsJob(run: 1234, job: 5678))
        #expect(job("https://github.com/acme/api/actions/runs/1234/jobs/5678?pr=42") == ActionsJob(run: 1234, job: 5678))
        #expect(job("https://github.com/acme/api/actions/runs/1234") == ActionsJob(run: 1234))
        #expect(job("https://github.com/acme/api/runs/5678") == nil)
        #expect(job("https://circleci.com/gh/acme/api/9") == nil)
        #expect(job("https://github.com/acme/api/actions/runs/latest") == nil)
    }

    @Test func theRepositoryIsReadOffThePullRequestURL() {
        #expect(PullRequest.repository(fromURL: URL(string: "https://github.com/acme/api/pull/42")!) == "acme/api")
        #expect(PullRequest.repository(fromURL: URL(string: "https://github.com/acme/api/pull/42/files")!) == "acme/api")
        #expect(PullRequest.repository(fromURL: URL(string: "https://github.com/acme/api")!) == nil)
    }

    @Test func theMergeMethodFollowsWhatTheRepositoryAllows() {
        #expect(MergeMethod.preferred(mergeCommit: true, squash: true, rebase: true) == .merge)
        #expect(MergeMethod.preferred(mergeCommit: false, squash: true, rebase: true) == .squash)
        #expect(MergeMethod.preferred(mergeCommit: false, squash: false, rebase: true) == .rebase)
        #expect(MergeMethod.preferred(mergeCommit: false, squash: false, rebase: false) == nil)
    }

    @Test func theLogTailIsCleanedAndBounded() {
        let log = (1...300).map { "test\tRun tests\t2026-09-11T08:12:03.1234567Z line \($0)" }.joined(separator: "\n") + "\n"
        let tail = PullRequestPrompts.logTail(log)
        let lines = tail.split(separator: "\n")
        #expect(lines.count == PullRequestPrompts.logLines && lines.first == "line 151" && lines.last == "line 300")
        #expect(PullRequestPrompts.logTail(String(repeating: "x", count: 50), characters: 10) == String(repeating: "x", count: 10))
        #expect(PullRequestPrompts.cleanLine("plain line") == "plain line")
        #expect(PullRequestPrompts.cleanLine("job\tstep\tno timestamp here") == "no timestamp here")
    }

    @Test func theThreadIsToldWhatFailedAndWhatToDo() {
        let check = PullRequestCheck(name: "test", workflow: "CI", state: .failing,
                                     detailsURL: URL(string: "https://github.com/acme/api/actions/runs/1/job/2"))
        let text = PullRequestPrompts.checkFailed(check, pullRequest: 42, log: "job\tstep\t2026-09-11T08:00:00Z Expected 3, got 4")
        #expect(text.hasPrefix("The check “CI / test” failed on pull request #42. Here is the end of its log:\n\n```\nExpected 3, got 4\n```"))
        #expect(PullRequestPrompts.checkFailed(check, pullRequest: 42, log: nil).contains("could not be fetched; it is at https://github.com/acme/api/actions/runs/1/job/2"))
        let conflicts = PullRequestPrompts.fixConflicts(pullRequest: 42, base: "main", branch: "feat/cache")
        #expect(conflicts.contains("`git merge origin/main`") && conflicts.contains("push feat/cache"))
    }
}
