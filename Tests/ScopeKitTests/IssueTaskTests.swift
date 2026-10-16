import Foundation
import Testing
import ScopeCore
import ScopeDrivers
import ScopeGit
@testable import ScopeTasks

/// A task from a GitHub issue: how the reference is read, what the brief becomes, what the record keeps.
@Suite struct IssueTaskTests {
    let issue = Issue(number: 12, title: "Login flakes on Safari", body: "Steps:\n1. open\n2. click", labels: ["bug", "front"],
                      url: URL(string: "https://github.com/acme/api/issues/12")!)

    @Test func issueReferencesAreParsedOnPurpose() {
        #expect(PullRequestReference.parseIssue("12") == PullRequestReference(number: 12, isIssue: true))
        #expect(PullRequestReference.parseIssue("#12") == PullRequestReference(number: 12, isIssue: true))
        #expect(PullRequestReference.parseIssue("acme/api#12") == PullRequestReference(number: 12, owner: "acme", repo: "api", isIssue: true))
        #expect(PullRequestReference.parseIssue("https://github.com/acme/api/issues/12")
                == PullRequestReference(number: 12, host: "github.com", owner: "acme", repo: "api", isIssue: true))
        #expect(PullRequestReference.parseIssue("https://github.com/acme/api/pull/12") == nil)
        #expect(PullRequestReference.parseIssue("0") == nil)
    }

    @Test func theStartPointRuleReadsIssueURLsAndMarksThem() {
        let worked = PullRequestReference.startPoint(in: "fix https://github.com/acme/api/issues/12 please")
        #expect(worked?.isIssue == true && worked?.number == 12 && worked?.repo == "api")
        #expect(PullRequestReference.startPoint(in: "https://github.com/acme/api/issues/12")?.isIssue == true)
        // Cited for context, not asked for.
        #expect(PullRequestReference.startPoint(in: "Add retries to the client (see https://github.com/acme/api/issues/12 for the story)") == nil)
        // A bare number says nothing either way; `gh` decides.
        #expect(PullRequestReference.startPoint(in: "fix #12")?.isIssue == false)
        // `detect` (the `--pr` shape) still never reads an issue.
        #expect(PullRequestReference.detect(in: "https://github.com/acme/api/issues/12") == nil)
    }

    @Test func theBriefOpensOnTheIssue() {
        let brief = IssueBrief.prefixed("fix #12 and add a test", with: issue)
        #expect(brief.hasPrefix("# Issue #12: Login flakes on Safari"))
        #expect(brief.contains("Labels: bug, front"))
        #expect(brief.contains("1. open"))
        #expect(brief.contains("Closes #12"))
        #expect(brief.hasSuffix("---\n\nfix #12 and add a test"))
        // A request that is the reference alone adds nothing after the issue.
        #expect(!IssueBrief.prefixed("#12", with: issue).contains("---"))
        #expect(!IssueBrief.prefixed(issue.url.absoluteString, with: issue).contains("---"))
        let long = Issue(number: 1, title: "t", body: String(repeating: "x", count: IssueBrief.bodyLimit + 50), url: issue.url)
        #expect(IssueBrief.prefixed("", with: long).contains(String(repeating: "x", count: IssueBrief.bodyLimit) + "…"))
        #expect(IssueBrief.title(for: issue) == "Login flakes on Safari")
    }

    @Test func ghJSONIsParsed() throws {
        let json = #"{"number":12,"title":"Login flakes","body":"text","labels":[{"name":"bug"}],"url":"https://github.com/acme/api/issues/12","state":"OPEN"}"#
        let parsed = try Issue.parseOne(json: Data(json.utf8))
        #expect(parsed.number == 12 && parsed.labels == ["bug"] && parsed.repository == "acme/api")
        let bare = try Issue.parseOne(json: Data(#"{"number":3,"title":"t","url":"https://github.com/a/b/issues/3"}"#.utf8))
        #expect(bare.body == "" && bare.labels.isEmpty)
    }

    @Test func theRecordKeepsTheIssueAndTheContextFileNamesIt() throws {
        var record = TaskRecord(scopeID: ScopeID.generate(), scopeRoot: "/s", scopeSlug: "s", name: "Fix login", slug: "fix-login",
                                branch: "fix/login", root: "/s/t", issue: LinkedIssue(issue))
        record.repos = [TaskRepo(repoRelativePath: "api", sandboxPath: "/s/t/api", branch: "fix/login")]
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(TaskRecord.self, from: data)
        #expect(back.issue == LinkedIssue(number: 12, url: issue.url, title: issue.title))
        let markdown = TaskProjection.agentsMarkdown(task: record, otherRepos: [], scopeName: "s")
        #expect(markdown.contains("- Issue: #12 https://github.com/acme/api/issues/12") && markdown.contains("Closes #12"))
    }

    @Test func theMicrosessionMayAnswerWithAnIssue() async throws {
        let prompt = TaskProposer.metaPrompt(request: "fix the flaky login issue", evidence: BranchEvidence())
        #expect(prompt.contains("gh issue view") && prompt.contains("Rules for \"issue\""))
        let proposal = await TaskProposer(profile: nil, runner: NoRunner(), home: URL(fileURLWithPath: "/tmp"))
            .finalize(output: #"{"title":"Fix login","slug":"fix-login","branch":"fix/login","issue":{"number":12,"repo":"acme/api"}}"#,
                      driverName: "d", prompt: "fix the flaky login issue", evidence: BranchEvidence(), takenSlugs: [])
        #expect(proposal.issue == PullRequestReference(number: 12, owner: "acme", repo: "api", isIssue: true))
        #expect(proposal.pullRequest == nil)
    }

    private struct NoRunner: HeadlessRunner {
        func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, terminationReason: .exit, stdout: Data(), stderr: Data())
        }
    }
}
