import Foundation
import ScopeCore
import ScopeGit
import Synchronization
import Testing
@testable import ScopeControl

/// `ReleaseRunner` against a scripted double: which processes it runs, in what order, and what stops it.
@Suite struct ReleaseRunnerTests {
    /// Answers each command from `respond`, records every call. Side effects (a clone creating files) live in `respond`.
    final class FakeRunner: ReleaseCommandRunner, @unchecked Sendable {
        private let log = Mutex<[ReleaseCommand]>([])
        private let environments = Mutex<[[String: String]]>([])
        let respond: @Sendable (ReleaseCommand) -> ReleaseCommandOutcome

        init(respond: @escaping @Sendable (ReleaseCommand) -> ReleaseCommandOutcome) {
            self.respond = respond
        }

        func run(_ command: ReleaseCommand, environment: [String: String], timeout: Duration,
                 onOutput: @escaping @Sendable (String) -> Void) async -> ReleaseCommandOutcome {
            log.withLock { $0.append(command) }
            environments.withLock { $0.append(environment) }
            let outcome = respond(command)
            if !outcome.output.isEmpty { onOutput(outcome.output) }
            return outcome
        }

        var commands: [ReleaseCommand] { log.withLock { $0 } }
        var lines: [String] { commands.map(\.line) }
        var lastEnvironment: [String: String]? { environments.withLock { $0.last } }
    }

    /// What the runner said while it worked.
    final class Progress: Sendable {
        private let lines = Mutex<[String]>([])
        func note(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    static let target = ReleaseTarget(repo: "api", scopeSlug: "acme", originURL: "git@github.com:acme/api.git", name: "acme-api")
    static let symref = "ref: refs/heads/main\tHEAD\n0123456789abcdef0123456789abcdef01234567\tHEAD\n"
    static let greenRuns = #"[{"name":"CI","status":"completed","conclusion":"success","event":"push","workflowName":"CI","headBranch":"main"}]"#

    struct Fixture {
        let home: URL
        let runner: FakeRunner
        let release: ReleaseRunner
        let progress = Progress()

        var checkout: URL { release.checkout(for: ReleaseRunnerTests.target) }

        init(gh: Bool = true, cliff: Bool = true, respond: @escaping @Sendable (ReleaseCommand, URL) -> ReleaseCommandOutcome?) {
            let home = FileManager.default.temporaryDirectory.appending(path: "release-runner-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            let checkout = ScopeHome.releasesURL(home: home).appending(path: ReleaseRunnerTests.target.name, directoryHint: .isDirectory)
            let runner = FakeRunner { command in
                if let answer = respond(command, checkout) { return answer }
                // The defaults of a happy path.
                switch command.arguments.first {
                case "ls-remote" where command.arguments.contains("--symref"): return .init(exitCode: 0, output: ReleaseRunnerTests.symref)
                case "ls-remote": return .init(exitCode: 0, output: "")
                case "rev-parse": return .init(exitCode: 0, output: "0123456789abcdef0123456789abcdef01234567\n")
                case "run" where command.arguments.contains("--commit"): return .init(exitCode: 0, output: ReleaseRunnerTests.greenRuns)
                case "run": return .init(exitCode: 0, output: "[]")
                default: return .init(exitCode: 0, output: "")
                }
            }
            self.home = home
            self.runner = runner
            self.release = ReleaseRunner(home: home, gitPath: "/usr/bin/git", ghPath: gh ? "/opt/homebrew/bin/gh" : nil,
                                         cliffPath: cliff ? "/opt/homebrew/bin/git-cliff" : nil, bashPath: "/bin/bash",
                                         environment: ["PATH": "/usr/bin", "SCOPE_THREAD": "abc", "SCOPE_TASK_ROOT": "/t", "HOME": "/Users/me"],
                                         runner: runner)
        }

        func run(_ params: ReleaseParams = ReleaseParams()) async -> Result<ReleaseResult, ControlError> {
            let progress = progress
            return await release.release(ReleaseRunnerTests.target, params: params) { line in progress.note(line) }
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }

    /// What a clone would leave behind: the checkout folder, with or without the release script.
    static func materialize(_ checkout: URL, script: Bool) {
        try? FileManager.default.createDirectory(at: checkout.appending(path: ".git"), withIntermediateDirectories: true)
        guard script else { return }
        let file = checkout.appending(path: ReleaseRunner.scriptPath, directoryHint: .notDirectory)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/usr/bin/env bash\n".write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Pure pieces

    @Test func theDefaultBranchComesFromTheRemote() {
        #expect(ReleaseRunner.defaultBranch(fromLsRemote: Self.symref) == "main")
        #expect(ReleaseRunner.defaultBranch(fromLsRemote: "ref: refs/heads/trunk\tHEAD\nabc\tHEAD\n") == "trunk")
        #expect(ReleaseRunner.defaultBranch(fromLsRemote: "abc\tHEAD\n") == nil)
        #expect(ReleaseRunner.defaultBranch(fromLsRemote: "") == nil)
    }

    @Test func theTagIsReadFromTheScript() {
        #expect(ReleaseRunner.tag(inScriptOutput: "==> Release notes for v0.4.0 (v0.3.0..HEAD):\n### Added\n") == "v0.4.0")
        #expect(ReleaseRunner.tag(inScriptOutput: "==> Pushing main and v0.4.0\n==> v0.4.0 pushed. The Release workflow…") == "v0.4.0")
        #expect(ReleaseRunner.tag(inScriptOutput: "==> v1.0.0-rc.1 pushed.") == "v1.0.0-rc.1")
        #expect(ReleaseRunner.tag(inScriptOutput: "error: not on main") == nil)
        #expect(ReleaseVersion.isValid("1.2.3") && ReleaseVersion.isValid("1.2.3-rc.1") && !ReleaseVersion.isValid("v1.2.3") && !ReleaseVersion.isValid("1.2"))
        #expect(ReleaseVersion.stripped(" v1.2.3\n") == "1.2.3")
    }

    @Test func ciRunsFoldIntoOneVerdict() throws {
        func verdict(_ json: String) throws -> ReleaseCIVerdict { try ReleaseCI.verdict(json: Data(json.utf8)) }
        #expect(try verdict("[]") == .noRuns)
        #expect(try verdict(Self.greenRuns) == .green(runs: 1))
        #expect(try verdict(#"[{"workflowName":"CI","status":"completed","conclusion":"skipped"},{"workflowName":"Lint","status":"completed","conclusion":"success"}]"#) == .green(runs: 2))
        #expect(try verdict(#"[{"workflowName":"CI","status":"in_progress","conclusion":""}]"#) == .pending(["CI"]))
        #expect(try verdict(#"[{"workflowName":"CI","status":"completed","conclusion":"failure"},{"workflowName":"Lint","status":"queued"}]"#) == .failed(["CI"]))
        #expect(ReleaseCIVerdict.failed(["CI"]).line == "red: CI")
        let running = #"[{"workflowName":"Release","status":"in_progress","event":"push","headBranch":"v0.9.0"},{"workflowName":"CI","status":"in_progress","event":"push","headBranch":"feat/x"},{"workflowName":"Build","status":"queued","event":"push","headBranch":"v1.0.0-rc.1"}]"#
        #expect(try ReleaseCI.releaseRuns(json: Data(running.utf8)) == ["Release on v0.9.0", "Build on v1.0.0-rc.1"])
    }

    @Test func theOutputKeepsItsEnd() {
        var output = BoundedOutput(limit: 40)
        output.append("first line that is long enough\n")
        #expect(!output.truncated)
        output.append("second\nthird line is the end\n")
        #expect(output.truncated)
        #expect(output.text.utf8.count <= 40)
        #expect(output.text.hasSuffix("third line is the end\n"))
        #expect(output.text.first != "\n")
    }

    @Test func theEnvironmentDropsTheThreadAndSilencesPrompts() {
        let fixture = Fixture { _, _ in nil }
        defer { fixture.remove() }
        let environment = fixture.release.commandEnvironment
        #expect(environment["PATH"] == "/usr/bin" && environment["HOME"] == "/Users/me")
        #expect(!environment.keys.contains { $0.hasPrefix("SCOPE_") })
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0" && environment["GH_PROMPT_DISABLED"] == "1")
    }

    // MARK: The run

    @Test func aRemoteWithoutADefaultBranchReleasesNothing() async {
        let fixture = Fixture { command, _ in
            command.arguments.contains("--symref") ? .init(exitCode: 0, output: "abc\tHEAD\n") : nil
        }
        defer { fixture.remove() }
        guard case .failure(let error) = await fixture.run(ReleaseParams(version: "1.0.0")) else {
            Issue.record("no default branch, no release")
            return
        }
        #expect(error.message.contains("no default branch"))
        #expect(fixture.runner.lines == ["git ls-remote --symref git@github.com:acme/api.git HEAD"])
    }

    @Test func aFreshCloneThenTheScriptWithTheVersion() async throws {
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone":
                Self.materialize(checkout, script: true)
                return .init(exitCode: 0)
            case let path? where path.hasSuffix(ReleaseRunner.scriptPath):
                return .init(exitCode: 0, output: "==> Fetching origin/main and tags\n==> Pushing main and v1.2.3 to origin (atomic)\n==> v1.2.3 pushed.\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        let result = try await fixture.run(ReleaseParams(version: "1.2.3")).get()
        #expect(result.released && !result.dryRun)
        #expect(result.tag == "v1.2.3" && result.branch == "main" && result.head.hasPrefix("0123456789ab"))
        #expect(result.ci == "green (1 run)" && result.method == ReleaseRunner.scriptPath)
        #expect(result.checkout == fixture.checkout.path && result.checkout.hasPrefix(fixture.home.path))
        #expect(result.output.contains("v1.2.3 pushed") && !result.truncated)

        let lines = fixture.runner.lines
        #expect(lines[0] == "git ls-remote --symref git@github.com:acme/api.git HEAD")
        #expect(lines[1] == "git clone --quiet --filter=blob:none --branch main --single-branch git@github.com:acme/api.git \(fixture.checkout.path)")
        #expect(lines[2] == "git rev-parse HEAD")
        #expect(lines[3].hasPrefix("gh run list --status in_progress") && lines[4].hasPrefix("gh run list --status queued"))
        #expect(lines[5].hasPrefix("gh run list --commit 0123456789abcdef0123456789abcdef01234567"))
        #expect(lines[6] == "bash \(fixture.checkout.path)/scripts/release.sh 1.2.3 --yes")
        #expect(lines.count == 7)
        // The script runs in the clone, with the thread's variables gone and the prompts off.
        #expect(fixture.runner.commands.last?.directory == fixture.checkout)
        #expect(fixture.runner.lastEnvironment?["SCOPE_THREAD"] == nil && fixture.runner.lastEnvironment?["GIT_TERMINAL_PROMPT"] == "0")
        // The script's lines came back as they were printed.
        let progress = fixture.progress.all
        #expect(progress.contains("==> v1.2.3 pushed."))
        #expect(progress.contains { $0.hasPrefix("cloning origin/main of api") })
    }

    @Test func anExistingCloneIsFetchedAndResetAndADryRunPassesTheFlag() async throws {
        let fixture = Fixture { command, _ in
            guard let path = command.arguments.first, path.hasSuffix(ReleaseRunner.scriptPath) else { return nil }
            return .init(exitCode: 0, output: "==> Release notes for v0.5.0 (v0.4.0..HEAD):\n### Added\n- things\n==> --dry-run: nothing changed\n")
        }
        defer { fixture.remove() }
        Self.materialize(fixture.checkout, script: true)
        let result = try await fixture.run(ReleaseParams(dryRun: true)).get()
        #expect(!result.released && result.dryRun)
        #expect(result.tag == "v0.5.0")
        let lines = fixture.runner.lines
        #expect(!lines.contains { $0.hasPrefix("git clone") })
        #expect(lines[1] == "git remote set-url origin git@github.com:acme/api.git")
        #expect(lines[2] == "git fetch --quiet --prune --prune-tags --tags --force origin main")
        #expect(lines[3] == "git checkout --quiet -B main origin/main")
        #expect(lines[4] == "git reset --quiet --hard origin/main")
        #expect(lines[5] == "git clean --quiet -fdx")
        #expect(lines.last == "bash \(fixture.checkout.path)/scripts/release.sh --yes --dry-run")
    }

    @Test func aRedOrRunningCIIsRefusedUnlessForced() async throws {
        let red = #"[{"workflowName":"CI","status":"completed","conclusion":"failure"}]"#
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: true); return .init(exitCode: 0)
            case "run" where command.arguments.contains("--commit"): return .init(exitCode: 0, output: red)
            case let path? where path.hasSuffix(ReleaseRunner.scriptPath): return .init(exitCode: 0, output: "==> v1.0.0 pushed.\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        guard case .failure(let error) = await fixture.run(ReleaseParams(version: "1.0.0")) else {
            Issue.record("red CI must refuse")
            return
        }
        #expect(error.message.contains("not green") && error.message.contains("red: CI"))
        #expect(error.detail?.contains("--force") == true)
        #expect(!fixture.runner.lines.contains { $0.hasPrefix("bash") })

        let forced = try await fixture.run(ReleaseParams(version: "1.0.0", force: true)).get()
        #expect(forced.released && forced.ci == "red: CI (forced)")
    }

    @Test func aReleaseAlreadyRunningIsRefusedEvenWhenForced() async {
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: true); return .init(exitCode: 0)
            case "run" where command.arguments.contains("in_progress"):
                return .init(exitCode: 0, output: #"[{"workflowName":"Release","status":"in_progress","event":"push","headBranch":"v0.9.0"}]"#)
            default: return nil
            }
        }
        defer { fixture.remove() }
        guard case .failure(let error) = await fixture.run(ReleaseParams(version: "1.0.0", force: true)) else {
            Issue.record("two releases at once")
            return
        }
        #expect(error.message.contains("already running"))
        #expect(error.detail?.contains("Release on v0.9.0") == true)
    }

    @Test func withoutGhTheCheckIsSkippedAndSaidSo() async throws {
        let fixture = Fixture(gh: false) { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: true); return .init(exitCode: 0)
            case let path? where path.hasSuffix(ReleaseRunner.scriptPath): return .init(exitCode: 0, output: "==> v1.0.0 pushed.\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        let result = try await fixture.run(ReleaseParams(version: "1.0.0")).get()
        #expect(result.ci == "not checked: gh is not installed")
        #expect(!fixture.runner.lines.contains { $0.hasPrefix("gh") })
    }

    @Test func aFailingScriptIsAFailureWithItsOutput() async {
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: true); return .init(exitCode: 0)
            case let path? where path.hasSuffix(ReleaseRunner.scriptPath): return .init(exitCode: 1, output: "error: tag v1.0.0 already exists on origin\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        guard case .failure(let error) = await fixture.run(ReleaseParams(version: "1.0.0")) else {
            Issue.record("exit 1 is a failure")
            return
        }
        #expect(error.code == .failed && error.message.contains("exit 1"))
        #expect(error.detail?.contains("already exists") == true)
    }

    @Test func withoutAScriptItTagsAndPushesTheTagAlone() async throws {
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: false); return .init(exitCode: 0)
            case "--bumped-version": return .init(exitCode: 0, output: "v2.0.0\n")
            case "--unreleased": return .init(exitCode: 0, output: "### Added\n- a thing\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        let preview = try await fixture.run(ReleaseParams(dryRun: true)).get()
        #expect(!preview.released && preview.tag == "v2.0.0" && preview.method == "git tag")
        #expect(preview.output.contains("annotated tag v2.0.0") && preview.output.contains("- a thing") && preview.output.contains("nothing changed"))
        #expect(!fixture.runner.lines.contains { $0.hasPrefix("git tag") || $0.hasPrefix("git push") })

        let shipped = try await fixture.run().get()
        #expect(shipped.released && shipped.tag == "v2.0.0")
        let lines = fixture.runner.lines
        #expect(lines.contains("git-cliff --bumped-version"))
        #expect(lines.contains("git ls-remote --tags origin refs/tags/v2.0.0"))
        #expect(lines.contains("git tag -a --cleanup=verbatim v2.0.0 -m acme-api 2.0.0 -m ### Added\n- a thing"))
        #expect(lines.last == "git push origin refs/tags/v2.0.0")
    }

    @Test func withoutAScriptAnExistingTagOrAMissingCliffStopsIt() async {
        let taken = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: false); return .init(exitCode: 0)
            case "ls-remote" where command.arguments.contains("--tags"): return .init(exitCode: 0, output: "abc\trefs/tags/v1.0.0\n")
            default: return nil
            }
        }
        defer { taken.remove() }
        guard case .failure(let exists) = await taken.run(ReleaseParams(version: "1.0.0")) else {
            Issue.record("an existing tag is refused")
            return
        }
        #expect(exists.message.contains("already exists"))

        let noCliff = Fixture(cliff: false) { command, checkout in
            if command.arguments.first == "clone" { Self.materialize(checkout, script: false); return .init(exitCode: 0) }
            return nil
        }
        defer { noCliff.remove() }
        guard case .failure(let missing) = await noCliff.run() else {
            Issue.record("no version and no git-cliff")
            return
        }
        #expect(missing.message.contains("git-cliff"))
    }

    /// Real git, a bare origin and a stand-in `scripts/release.sh`: the clone lands under the home, the script runs in
    /// it with the arguments the real one takes, its lines stream back, and the next run reuses the clone.
    @Test func theRealRunnerClonesAndRunsTheScriptAgainstABareOrigin() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        try scope.write(repo, "scripts/release.sh", """
            #!/usr/bin/env bash
            echo "==> args: $*"
            echo "==> pwd: $(pwd -P)"
            echo "==> branch: $(git rev-parse --abbrev-ref HEAD)"
            [ -z "${SCOPE_THREAD:-}" ] || { echo "SCOPE_THREAD leaked" >&2; exit 3; }
            echo "==> Release notes for v0.1.0 (first commit..HEAD):"
            echo "==> --dry-run: nothing changed"
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appending(path: "scripts/release.sh").path)
        try await scope.commit(in: repo, "chore: release script")
        try await scope.client(for: repo).run(["push", "-q", "origin", "main"])
        let origin = try await scope.client(for: repo).run(["remote", "get-url", "origin"]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)

        let target = ReleaseTarget(repo: "api", scopeSlug: "acme", originURL: origin, name: "acme-api")
        var environment = scope.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment["SCOPE_THREAD"] = "3f9a2c17be04"
        let runner = ReleaseRunner(home: scope.home, gitPath: scope.gitPath, ghPath: nil, cliffPath: nil,
                                   environment: environment, runner: ProcessReleaseRunner())
        let progress = Progress()
        let first = try await runner.release(target, params: ReleaseParams(dryRun: true)) { progress.note($0) }.get()
        #expect(first.dryRun && !first.released && first.tag == "v0.1.0" && first.branch == "main")
        #expect(first.checkout == runner.checkout(for: target).path)
        #expect(first.output.contains("==> args: --yes --dry-run"), "\(first.output)")
        // `pwd -P` says /private/var where the fixture says /var: compare what is under the home.
        #expect(first.output.contains("==> pwd: ") && first.output.contains("/scope-home/releases/acme-api\n"), "\(first.output)")
        #expect(first.output.contains("==> branch: main"))
        #expect(first.ci == "not checked: gh is not installed")
        #expect(progress.all.contains("==> args: --yes --dry-run"))
        #expect(FileManager.default.fileExists(atPath: runner.checkout(for: target).appending(path: "scripts/release.sh").path))

        // A second release reuses the clone and sees what moved on origin since.
        try scope.write(repo, "NEW.md", "new\n")
        try await scope.commit(in: repo, "feat: new")
        try await scope.client(for: repo).run(["push", "-q", "origin", "main"])
        let head = try await scope.client(for: repo).run(["rev-parse", "HEAD"]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = try await runner.release(target, params: ReleaseParams(version: "0.2.0", dryRun: true)) { _ in }.get()
        #expect(second.head == head)
        #expect(second.tag == "v0.2.0" && second.output.contains("==> args: 0.2.0 --yes --dry-run"))
    }

    @Test func theScriptOutputIsBoundedInTheAnswer() async throws {
        let fixture = Fixture { command, checkout in
            switch command.arguments.first {
            case "clone": Self.materialize(checkout, script: true); return .init(exitCode: 0)
            case let path? where path.hasSuffix(ReleaseRunner.scriptPath):
                let noise = String(repeating: "a line of notes that goes on and on\n", count: 2000)
                return .init(exitCode: 0, output: noise + "==> v1.0.0 pushed.\n")
            default: return nil
            }
        }
        defer { fixture.remove() }
        let result = try await fixture.run(ReleaseParams(version: "1.0.0")).get()
        #expect(result.truncated)
        #expect(result.output.utf8.count <= ReleaseRunner.outputLimit)
        #expect(result.output.hasSuffix("==> v1.0.0 pushed.\n"))
    }
}
