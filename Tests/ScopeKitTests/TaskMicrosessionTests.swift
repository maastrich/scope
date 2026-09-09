import Foundation
import Synchronization
import Testing
import ScopeCore
import ScopeDrivers
import ScopeGit
@testable import ScopeTasks

/// The microsession side of `TaskProposer`: the light argv it runs, the repositories and the pull request
/// it may answer with, and what happens to an answer that names something the scope does not have.
@Suite struct TaskMicrosessionTests {
    let home = URL(fileURLWithPath: "/tmp/scope-microsession-tests", isDirectory: true)
    let request = "Rebase the auth refresh pull request on front"
    let candidates = [
        RepoCandidate(path: "front", name: "front", remote: RemoteInfo(remote: "git@github.com:acme/front.git")),
        RepoCandidate(path: "api", name: "api", remote: RemoteInfo(remote: "git@github.com:acme/api.git")),
    ]

    /// A profile with both argvs, so the microsession's precedence can be seen.
    var claude: DriverProfile {
        DriverProfile(id: "claude-code", name: "Claude Code", command: "claude",
                      headless: ["claude", "-p", "{prompt}"],
                      headlessLight: ["claude", "-p", "{prompt}", "--model", "haiku", "--allowedTools", "Bash(gh pr view:*)"])
    }

    // MARK: The argv

    @Test func microsessionPrefersTheLightArgv() {
        #expect(claude.microsession == claude.headlessLight)
        var heavy = claude
        heavy.headlessLight = nil
        #expect(heavy.microsession == heavy.headless)
        var empty = claude
        empty.headlessLight = []
        #expect(empty.microsession == empty.headless)
    }

    @Test func runnerGetsTheLightArgv() async throws {
        final class Recorder: HeadlessRunner, Sendable {
            private let recorded = Mutex<[String]>([])
            var argv: [String] { recorded.withLock { $0 } }
            func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
                recorded.withLock { $0 = argv }
                return ProcessResult(exitCode: 0, terminationReason: .exit,
                                     stdout: Data(#"{"title":"T","slug":"t","branch":"feat/t"}"#.utf8), stderr: Data())
            }
        }
        let recorder = Recorder()
        _ = await TaskProposer(profile: claude, runner: recorder, home: home)
            .propose(prompt: request, evidence: BranchEvidence(), cwd: home, scopeRoot: home, takenSlugs: [])
        #expect(recorder.argv.contains("--model") && recorder.argv.contains("haiku"))
    }

    // MARK: The meta-prompt

    @Test func metaPromptListsTheRepositoriesAndTheToolRules() {
        let prompt = TaskProposer.metaPrompt(request: request, evidence: BranchEvidence(), candidates: candidates)
        #expect(prompt.contains("- front (front) — remote acme/front"))
        #expect(prompt.contains("- api (api) — remote acme/api"))
        #expect(prompt.contains("gh pr list") && prompt.contains("Read-only subcommands only"))
        #expect(prompt.contains("Never invent one"))
    }

    @Test func metaPromptWithoutCandidatesSaysSo() {
        let prompt = TaskProposer.metaPrompt(request: request, evidence: BranchEvidence())
        #expect(prompt.contains("(unknown)"))
    }

    // MARK: The answer

    @Test func answeredRepositoriesAreKeptInScopeOrder() async {
        let proposal = await finalize(#"{"title":"Refresh","slug":"refresh","branch":"feat/refresh","repos":["api","front"]}"#)
        #expect(proposal.repos == ["front", "api"])
    }

    @Test func inventedRepositoriesAreDropped() async {
        let proposal = await finalize(#"{"title":"T","slug":"t","branch":"feat/t","repos":["front","payments"]}"#)
        #expect(proposal.repos == ["front"])
    }

    @Test func aPullRequestAnswerCarriesNumberAndRepository() async {
        let proposal = await finalize(#"{"title":"T","slug":"t","branch":"feat/t","pull_request":{"number":6613,"repo":"acme/front"}}"#)
        #expect(proposal.pullRequest == PullRequestReference(number: 6613, owner: "acme", repo: "front"))
    }

    @Test func aPullRequestAnswerWithoutABranchIsStillRead() throws {
        let raw = try TaskProposer.parse(output: #"{"title":"T","slug":"t","pull_request":{"number":42}}"#)
        #expect(TaskProposer.reference(from: raw.pullRequest) == PullRequestReference(number: 42))
    }

    @Test func anAnswerWithNeitherBranchNorPullRequestIsRejected() {
        #expect(throws: TaskProposer.ParseError.missingBranch) {
            try TaskProposer.parse(output: #"{"title":"T","slug":"t"}"#)
        }
    }

    @Test func aNullPullRequestIsNoPullRequest() async {
        let proposal = await finalize(#"{"title":"T","slug":"t","branch":"feat/t","pull_request":null}"#)
        #expect(proposal.pullRequest == nil)
        #expect(proposal.repos.isEmpty)
    }

    /// Runs the driver-answer path with the two-repository scope above.
    private func finalize(_ output: String) async -> TaskProposal {
        await TaskProposer(profile: claude, runner: NeverRunner(), home: home)
            .finalize(output: output, driverName: "Claude Code", prompt: request,
                      evidence: BranchEvidence(), takenSlugs: [], candidates: candidates)
    }

    private struct NeverRunner: HeadlessRunner {
        func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, terminationReason: .exit, stdout: Data(), stderr: Data())
        }
    }
}
