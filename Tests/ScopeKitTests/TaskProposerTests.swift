import Synchronization
import Foundation
import Testing
import ScopeCore
import ScopeDrivers
import ScopeGit
@testable import ScopeTasks

@Suite struct TaskProposerTests {
    /// Canned driver output, or a thrown error.
    struct FakeRunner: HeadlessRunner {
        var output: String = ""
        var exitCode: Int32 = 0
        var error: (any Error)? = nil
        func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
            if let error { throw error }
            return ProcessResult(exitCode: exitCode, terminationReason: .exit, stdout: Data(output.utf8), stderr: Data("boom".utf8))
        }
    }

    private let home = URL(fileURLWithPath: "/tmp/scope-home", isDirectory: true)
    private let claude = DriverProfile(id: "claude-code", name: "Claude Code", command: "claude",
                                       headless: ["claude", "-p", "{prompt}", "--output-format", "json"])
    private let request = "Add a refresh-token flow to the auth service.\nIt must rotate tokens on every call."
    private let typed = BranchEvidence(branches: ["feat/login", "fix/crash-on-boot", "feat/sso", "chore/deps"], commitSubjects: ["feat: login", "fix: boot"], defaultBranch: "main")

    private func proposer(_ runner: FakeRunner, profile: DriverProfile? = nil) -> TaskProposer {
        TaskProposer(profile: profile ?? claude, runner: runner, home: home)
    }

    private func propose(_ runner: FakeRunner, evidence: BranchEvidence? = nil, taken: Set<String> = [], profile: DriverProfile? = nil) async -> TaskProposal {
        await proposer(runner, profile: profile).propose(prompt: request, evidence: evidence ?? typed, cwd: home, scopeRoot: home, takenSlugs: taken)
    }

    // MARK: Level 1

    @Test func claudeEnvelopeIsUnwrapped() async throws {
        let answer = #"{"title":"Refresh-token flow for auth","slug":"auth-refresh-token","branch":"feat/auth-refresh-token"}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": answer])
        let proposal = await propose(FakeRunner(output: String(decoding: envelope, as: UTF8.self)))
        #expect(proposal == TaskProposal(title: "Refresh-token flow for auth", slug: "auth-refresh-token", branch: "feat/auth-refresh-token", source: .driver(name: "Claude Code")))
    }

    @Test func fencedAnswerAndScopePrefixStripped() async {
        let fenced = "Sure:\n```json\n{\"title\":\"Auth tokens\",\"slug\":\"Auth Tokens!\",\"branch\":\"scope/auth-tokens\"}\n```"
        let proposal = await propose(FakeRunner(output: fenced))
        #expect(proposal.branch == "auth-tokens" && proposal.slug == "auth-tokens" && !proposal.isDerived)
    }

    @Test func invalidAnswersFallBack() async {
        for runner in [FakeRunner(output: "not json"), FakeRunner(output: #"{"title":"x"}"#), FakeRunner(exitCode: 1),
                       FakeRunner(error: SubprocessError.timedOut(after: .seconds(30))), FakeRunner(error: HeadlessError.commandNotFound("claude"))] {
            let proposal = await propose(runner)
            #expect(proposal.isDerived)
            #expect(proposal.branch == "feat/add-a-refresh-token-flow-to-the-auth-service")
            if case .derived(let reason) = proposal.source { #expect(reason != nil) }
        }
        let error = await propose(FakeRunner(output: #"{"type":"result","is_error":true,"result":"rate limited"}"#))
        #expect(error.source == .derived(reason: "driver failed: rate limited"))
    }

    @Test func noHeadlessArgvIsFallbackWithoutReason() async {
        let shell = DriverProfile(id: "shell", name: "Shell", command: "$SHELL")
        let proposal = await propose(FakeRunner(output: #"{"branch":"never/used"}"#), profile: shell)
        #expect(proposal.source == .derived(reason: nil) && proposal.branch.hasPrefix("feat/"))
        let none = await TaskProposer(profile: nil, runner: FakeRunner(), home: home)
            .propose(prompt: request, evidence: typed, cwd: home, scopeRoot: home, takenSlugs: [])
        #expect(none.isDerived)
    }

    @Test func driverBranchIsValidatedSanitisedAndMadeUnique() async {
        // Invalid ref → sanitised per component.
        let bad = await propose(FakeRunner(output: #"{"title":"T","slug":"t","branch":"Feat/Add Login..now"}"#))
        #expect(bad.branch == "feat/add-login-now")
        // Existing name → -2, -3 …
        let evidence = BranchEvidence(branches: ["feat/login", "feat/login-2"], defaultBranch: "main")
        let dup = await propose(FakeRunner(output: #"{"title":"T","slug":"t","branch":"feat/login"}"#), evidence: evidence)
        #expect(dup.branch == "feat/login-3")
        // Slug taken → -2; overlong title cut at a word boundary.
        let long = String(repeating: "word ", count: 20)
        let taken = await propose(FakeRunner(output: #"{"title":"\#(long)","slug":"t","branch":"feat/x"}"#), taken: ["t"])
        #expect(taken.slug == "t-2" && taken.title.count <= TaskProposer.titleLimit && !taken.title.hasSuffix(" "))
    }

    @Test func gitValidatorMatchesCheckRefFormat() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let validate = TaskProposer.gitRefValidator(client: await scope.client(for: repo))
        var results: [Bool] = []
        for name in ["feat/login", "mathis/wip-2", "feat/../x", "-flag", "a b", "x.lock", "HEAD"] {
            results.append(await validate(name))
        }
        #expect(results == [true, true, false, false, false, false, false])
        let plain = ["feat/login", "a..b", "@{x", "/lead", "trail/", "dot/.hidden", "ok/x.lock", ""]
        #expect(plain.map(TaskProposer.isPlausibleRefName) == [true, false, false, false, false, false, false, false])
    }

    @Test func metaPromptCarriesRequestAndEvidence() {
        let prompt = TaskProposer.metaPrompt(request: request, evidence: typed)
        #expect(prompt.contains("- feat/login") && prompt.contains("- fix: boot") && prompt.contains("Never use a `scope/` prefix"))
        #expect(prompt.contains("Add a refresh-token flow") && prompt.contains("Default branch: main") && prompt.contains("Conventional Commits"))
    }

    @Test func runnerGetsExpandedHeadlessArgv() async throws {
        final class Recorder: HeadlessRunner, Sendable {
            private let recorded = Mutex<[String]>([])
            var argv: [String] { recorded.withLock { $0 } }
            func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
                recorded.withLock { $0 = argv }
                return ProcessResult(exitCode: 0, terminationReason: .exit, stdout: Data(#"{"title":"T","slug":"t","branch":"feat/t"}"#.utf8), stderr: Data())
            }
        }
        let recorder = Recorder()
        _ = await TaskProposer(profile: claude, runner: recorder, home: home)
            .propose(prompt: request, evidence: typed, cwd: home, scopeRoot: home, takenSlugs: [])
        #expect(recorder.argv.count == 5 && recorder.argv[0] == "claude" && recorder.argv[1] == "-p")
        #expect(recorder.argv[2].contains("Task request:\n\(request)"))
    }

    // MARK: Level 0

    @Test func fallbackDerivesTitleSlugAndBranch() {
        let none = BranchEvidence()
        let feat = TaskProposer.fallback(prompt: "# add dark mode to the settings window.\n\ndetails", evidence: none, takenSlugs: [])
        #expect(feat == TaskProposal(title: "Add dark mode to the settings window", slug: "add-dark-mode-to-the-settings-window",
                                     branch: "feat/add-dark-mode-to-the-settings-window", source: .derived(reason: nil)))
        let fix = TaskProposer.fallback(prompt: "The login form crashes on submit", evidence: none, takenSlugs: [])
        #expect(fix.branch == "fix/the-login-form-crashes-on-submit")
        let bare = TaskProposer.fallback(prompt: "Investigate why the build is slow", evidence: none, takenSlugs: [])
        #expect(bare.branch == "investigate-why-the-build-is-slow")
        #expect(TaskProposer.fallback(prompt: "   \n", evidence: none, takenSlugs: []).title == "Task")
        #expect(TaskProposer.fallback(prompt: "x", evidence: none, takenSlugs: ["x", "x-2"]).slug == "x-3")
        let long = TaskProposer.fallback(prompt: "Refactor the very long pipeline of the ingestion service so that it streams records instead of buffering", evidence: none, takenSlugs: [])
        #expect(long.title.count <= 60 && long.title == "Refactor the very long pipeline of the ingestion service so")
    }

    @Test func conventionIsDetectedFromBranchLists() {
        // ≥ 3 share a user prefix → that prefix.
        let user = BranchEvidence(branches: ["mathis/wip", "mathis/login", "mathis/fix-2", "alice/x"], defaultBranch: "main")
        #expect(user.dominantPrefix == "mathis" && !user.usesTypePrefixes)
        #expect(TaskProposer.fallback(prompt: "Add SSO", evidence: user, takenSlugs: []).branch == "mathis/add-sso")
        // Type prefixes → the inferred type wins over the most frequent prefix.
        #expect(typed.usesTypePrefixes)
        #expect(TaskProposer.fallback(prompt: "Login crashes on boot", evidence: typed, takenSlugs: []).branch == "fix/login-crashes-on-boot")
        #expect(TaskProposer.fallback(prompt: "Rename the module", evidence: typed, takenSlugs: []).branch == "feat/rename-the-module")
        // Fewer than 3 → no convention; `scope/` never counts.
        let weak = BranchEvidence(branches: ["scope/a", "scope/b", "scope/c", "bob/x", "bob/y"], defaultBranch: "main")
        #expect(weak.dominantPrefix == nil)
        #expect(TaskProposer.fallback(prompt: "Rename the module", evidence: weak, takenSlugs: []).branch == "rename-the-module")
        // Existing branch names are avoided.
        let clash = BranchEvidence(branches: ["feat/add-sso"], defaultBranch: "main")
        #expect(TaskProposer.fallback(prompt: "Add SSO", evidence: clash, takenSlugs: []).branch == "feat/add-sso-2")
    }

    @Test func evidenceNormalisesRemoteNames() {
        let names = ["origin/HEAD", "origin/main", "origin/feat/a", "feat/a", "upstream/fix/b", "refs/heads/chore/c", "main"]
        #expect(BranchEvidence.normalize(names, defaultBranch: "main") == ["feat/a", "fix/b", "chore/c"])
        let commits = BranchEvidence(commitSubjects: ["feat(ui): x", "fix!: y", "Merge branch", "docs: z"])
        #expect(commits.usesConventionalCommits)
        #expect(!BranchEvidence(commitSubjects: ["Initial", "wip", "feat: x"]).usesConventionalCommits)
    }

    @Test func evidenceIsGatheredFromGit() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        for name in ["feat/one", "feat/two", "fix/three"] {
            try await client.run(["branch", name])
        }
        try await client.run(["push", "-q", "origin", "feat/one"])
        try scope.write(repo, "a.txt", "a\n")
        try await scope.commit(in: repo, "feat: add a")
        let evidence = await BranchEvidence.gather(repos: [repo], registry: scope.registry)
        #expect(evidence.defaultBranch == "main")
        #expect(Set(evidence.branches) == ["feat/one", "feat/two", "fix/three"])
        #expect(evidence.commitSubjects.first == "feat: add a" && evidence.commitSubjects.contains("initial"))
        #expect(evidence.usesTypePrefixes)
    }
}
