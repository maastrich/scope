import Foundation
import Synchronization
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// A runner that runs nothing: it remembers what it was asked and answers what the test says.
final class RecordingRunner: SandboxCommandRunner {
    struct Call: Sendable {
        var command: String
        var directory: URL
        var environment: [String: String]
    }

    private let calls = Mutex<[Call]>([])
    private let answer: @Sendable (String) -> CommandOutcome

    init(answer: @escaping @Sendable (String) -> CommandOutcome = { _ in CommandOutcome(exitCode: 0, output: "ok") }) {
        self.answer = answer
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func run(_ command: String, in directory: URL, environment: [String: String], timeout: Duration) async -> CommandOutcome {
        calls.withLock { $0.append(Call(command: command, directory: directory, environment: environment)) }
        return answer(command)
    }
}

@Suite(.serialized) struct SandboxSetupTests {
    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "scope-copy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ directory: URL, _ path: String, _ text: String = "x") throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Pure parts

    @Test func portsComeInBlocksOfTenAndSkipTheTakenOnes() {
        let first = PortAllocator.range.lowerBound
        #expect(PortAllocator.allocate(taken: []) == first)
        #expect(PortAllocator.allocate(taken: [first]) == first + 10)
        #expect(PortAllocator.allocate(taken: [first, first + 20]) == first + 10)
        // A hand-edited base inside a block still takes the whole block.
        #expect(PortAllocator.allocate(taken: [first + 3]) == first + 10)
        let every = stride(from: PortAllocator.range.lowerBound, to: PortAllocator.range.upperBound, by: 10)
        #expect(PortAllocator.allocate(taken: every) == nil)
    }

    @Test func configOverridesTheCardFieldByField() {
        let card = RepoContextSummary(path: "api", setup: "pnpm install", teardown: "docker compose down")
        let none = SandboxCommands.resolve(card: card, setupOverride: nil, teardownOverride: nil, copyFilesOverride: nil)
        #expect(none == SandboxCommands(setup: "pnpm install", teardown: "docker compose down", copyFiles: [".env*"]))
        let some = SandboxCommands.resolve(card: card, setupOverride: "make deps", teardownOverride: "  ",
                                           copyFilesOverride: [".env", "config/local.json"])
        #expect(some == SandboxCommands(setup: "make deps", teardown: nil, copyFiles: [".env", "config/local.json"]))
        #expect(SandboxCommands.resolve(card: nil, setupOverride: nil, teardownOverride: nil, copyFilesOverride: nil)
                == SandboxCommands())
    }

    @Test func scopeConfigFindsTheOverrideWhateverThePathSpelling() throws {
        let declaration = ScopeDeclaration(path: "/s/acme", slug: "acme",
                                           repoCommands: ["./api/": RepoCommandOverride(setup: "make")])
        #expect(declaration.commandOverride(for: "api")?.setup == "make")
        #expect(declaration.commandOverride(for: "web") == nil)
        let data = try JSONEncoder().encode(declaration)
        #expect(try JSONDecoder().decode(ScopeDeclaration.self, from: data).repoCommands == declaration.repoCommands)
    }

    @Test func commandsSeeTheTaskVariables() {
        let repo = TaskRepo(repoRelativePath: "api", sandboxPath: "/h/sandboxes/acme/auth/api", branch: "feat/auth")
        let task = TaskRecord(scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/s/acme",
                              scopeSlug: "acme", name: "Auth", slug: "auth", branch: "feat/auth",
                              root: "/h/sandboxes/acme/auth", repos: [repo], portBase: 41020)
        #expect(SandboxEnvironment.variables(task: task, repo: repo, basePath: "/s/acme/api", defaultBranch: "main") == [
            "SCOPE_TASK": "auth", "SCOPE_TASK_ROOT": "/h/sandboxes/acme/auth", "SCOPE_SCOPE": "acme",
            "SCOPE_SANDBOX": "/h/sandboxes/acme/auth/api", "SCOPE_BASE_PATH": "/s/acme/api",
            "SCOPE_DEFAULT_BRANCH": "main", "SCOPE_PORT": "41020",
        ])
        #expect(task.environment["SCOPE_PORT"] == "41020")
    }

    @Test func aLongLogKeepsItsEnd() {
        let long = String(repeating: "a", count: 100) + "the error"
        let bounded = SetupLog.bounded(long, limit: 50)
        #expect(bounded.count == 50 && bounded.hasSuffix("the error") && bounded.hasPrefix(SetupLog.cutMarker))
        #expect(SetupLog.bounded("short", limit: 50) == "short")
        let interrupted = TaskSetupRecord(state: .running, log: "npm install\n").normalizedAfterRestart
        #expect(interrupted.state == .failed && interrupted.log.contains("interrupted"))
    }

    // MARK: Copy plan

    @Test func envFilesAreCopiedAndExistingOnesKept() throws {
        let base = try tempDirectory()
        let sandbox = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: sandbox) }
        try write(base, ".env", "SECRET=1")
        try write(base, ".env.local")
        try write(base, ".env.example", "base copy")
        try write(base, "README.md")
        try write(base, "apps/web/.env")
        try write(sandbox, ".env.example", "tracked")

        let plan = SandboxFileCopy.plan(globs: [".env*", "apps/web/.env", "missing/.env"], base: base, sandbox: sandbox)
        #expect(plan.copies.map(\.relativePath) == [".env", ".env.local", "apps/web/.env"])
        #expect(plan.refusals.isEmpty)
        let result = SandboxFileCopy.apply(plan)
        #expect(result.copied == [".env", ".env.local", "apps/web/.env"] && result.failed.isEmpty)
        #expect(try String(contentsOf: sandbox.appending(path: ".env"), encoding: .utf8) == "SECRET=1")
        #expect(try String(contentsOf: sandbox.appending(path: ".env.example"), encoding: .utf8) == "tracked")
    }

    @Test func globsThatLeaveTheRepositoryAreRefused() throws {
        let base = try tempDirectory()
        let sandbox = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: sandbox) }
        let plan = SandboxFileCopy.plan(globs: ["../secrets", "/etc/hosts", "~/.ssh/id_rsa", "*/.env", "a/../../b"],
                                        base: base, sandbox: sandbox)
        #expect(plan.copies.isEmpty)
        #expect(plan.refusals.map(\.path) == ["../secrets", "/etc/hosts", "~/.ssh/id_rsa", "*/.env", "a/../../b"])
    }

    @Test func symlinksNeverCarryTheCopyElsewhere() throws {
        let base = try tempDirectory()
        let sandbox = try tempDirectory()
        let outside = try tempDirectory()
        defer { for url in [base, sandbox, outside] { try? FileManager.default.removeItem(at: url) } }
        try write(outside, "credentials", "private")
        try write(base, "real.env", "fine")
        let manager = FileManager.default
        // A source link out of the checkout is refused; one that stays inside is followed.
        try manager.createSymbolicLink(at: base.appending(path: ".env"), withDestinationURL: outside.appending(path: "credentials"))
        try manager.createSymbolicLink(at: base.appending(path: ".env.inside"), withDestinationURL: base.appending(path: "real.env"))
        // A sandbox folder that is a link would redirect the write.
        try write(base, "config/.env", "cfg")
        try manager.createSymbolicLink(at: sandbox.appending(path: "config"), withDestinationURL: outside)

        let plan = SandboxFileCopy.plan(globs: [".env*", "config/.env"], base: base, sandbox: sandbox)
        #expect(plan.copies.map(\.relativePath) == [".env.inside"])
        #expect(Set(plan.refusals.map(\.path)) == [".env", "config/.env"])
        _ = SandboxFileCopy.apply(plan)
        #expect(!manager.fileExists(atPath: outside.appending(path: ".env").path))
        #expect(try String(contentsOf: sandbox.appending(path: ".env.inside"), encoding: .utf8) == "fine")
    }

    // MARK: TaskManager

    @Test func setupCopiesThenRunsInEachSandboxWithItsVariables() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        try scope.write(api, ".env", "API_KEY=1")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api", "web"])
        let runner = RecordingRunner()
        let seen = Mutex<[SetupState]>([])

        let done = try await manager.runSetup(task.id, commands: ["api": SandboxCommands(setup: "pnpm install")],
                                              runCommands: true, runner: runner,
                                              onChange: { record in seen.withLock { $0.append(record.setupState) } })
        #expect(done.setupState == .succeeded)
        #expect(seen.withLock { $0 } == [.running, .succeeded])
        #expect(done.setup?.log.contains("[api] $ pnpm install\nok\n[api] done") == true)
        let call = try #require(runner.recorded.first)
        #expect(runner.recorded.count == 1 && call.command == "pnpm install")
        #expect(call.directory == task.repos[0].sandboxURL)
        #expect(call.environment["SCOPE_SANDBOX"] == task.repos[0].sandboxPath)
        #expect(call.environment["SCOPE_BASE_PATH"] == api.filesystemPath)
        #expect(call.environment["SCOPE_DEFAULT_BRANCH"] == "main")
        #expect(call.environment["SCOPE_PORT"] == String(PortAllocator.range.lowerBound))

        // The .env reached the sandbox and stays out of the delta.
        let sandbox = task.repos[0].sandboxURL
        #expect(try String(contentsOf: sandbox.appending(path: ".env"), encoding: .utf8) == "API_KEY=1")
        let client = await scope.client(for: sandbox)
        #expect(try await !client.hasUncommittedChanges(at: sandbox))
        // Persisted.
        #expect(await makeManager(scope).loadAll().isEmpty)
    }

    @Test func aFailingSetupIsFailedWithItsOutputAndTheOthersStillRun() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api", "web"])
        let runner = RecordingRunner { command in
            command == "boom" ? CommandOutcome(exitCode: 2, output: "ERR! missing lockfile") : CommandOutcome(exitCode: 0)
        }
        let done = try await manager.runSetup(task.id, commands: ["api": SandboxCommands(setup: "boom"),
                                                                  "web": SandboxCommands(setup: "make")],
                                              runCommands: true, runner: runner)
        #expect(done.setupState == .failed)
        #expect(runner.recorded.map(\.command) == ["boom", "make"])
        #expect(done.setup?.log.contains("ERR! missing lockfile\n[api] failed: exit 2") == true)
    }

    @Test func untickedOrCommandlessSetupIsSkippedButStillCopies() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        try scope.write(api, ".env", "A=1")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let runner = RecordingRunner()
        let unticked = try await manager.runSetup(task.id, commands: ["api": SandboxCommands(setup: "make")],
                                                  runCommands: false, runner: runner)
        #expect(unticked.setupState == .skipped && runner.recorded.isEmpty)
        #expect(scope.exists(task.repos[0].sandboxURL.appending(path: ".env")))
        let nothing = try await manager.runSetup(task.id, commands: [:], runCommands: true, runner: runner)
        #expect(nothing.setupState == .skipped && runner.recorded.isEmpty)
    }

    @Test func aFailedTeardownKeepsTheSandbox() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let commands = ["api": SandboxCommands(teardown: "docker compose down")]

        let failing = TaskManager.Teardown(commands: commands, runner: RecordingRunner { _ in CommandOutcome(exitCode: 1, output: "no daemon") })
        await #expect(throws: TaskError.self) { try await manager.close(task.id, deleteBranch: false, teardown: failing) }
        #expect(scope.exists(task.repos[0].sandboxURL))
        #expect(await manager.task(task.id) != nil)
        await #expect(throws: TaskError.self) { try await manager.archive(task.id, teardown: failing) }
        #expect(await manager.task(task.id)?.isArchived == false)

        let passing = RecordingRunner()
        try await manager.close(task.id, deleteBranch: false, teardown: TaskManager.Teardown(commands: commands, runner: passing))
        #expect(passing.recorded.map(\.command) == ["docker compose down"])
        #expect(passing.recorded.first?.environment["SCOPE_TASK"] == task.slug)
        #expect(!scope.exists(task.repos[0].sandboxURL))
    }

    @Test func aRestartFailsAnInterruptedSetupAndHandsOutMissingPorts() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let first = try await manager.create(name: "One", branch: "feat/one", in: scope.declaration, repos: ["api"])
        #expect(first.portBase == PortAllocator.range.lowerBound)
        // A record from before ports, caught mid-setup by a quit.
        var old = TaskRecord(scopeID: scope.declaration.id, scopeRoot: scope.scopeRoot.path, scopeSlug: "acme",
                             name: "Old", slug: "old", branch: "feat/old", root: scope.home.appending(path: "sandboxes/acme/old").path,
                             createdAt: TaskRecord.roundedToMilliseconds(.now.addingTimeInterval(60)))
        old.setup = TaskSetupRecord(state: .running, log: "pnpm install\n")
        try await TaskRecordStore(home: scope.home).save(old)

        let reloaded = makeManager(scope)
        #expect(await reloaded.loadAll().isEmpty)
        let fixed = try #require(await reloaded.task(old.id))
        #expect(fixed.setupState == .failed)
        #expect(fixed.portBase == PortAllocator.range.lowerBound + PortAllocator.blockSize)
        // Saved: a second launch sees the same answer.
        let again = makeManager(scope)
        _ = await again.loadAll()
        #expect(await again.task(old.id) == fixed)
    }

    @Test func theShellRunnerReportsExitAndOutput() async throws {
        let runner = ShellCommandRunner(shell: "/bin/sh", baseEnvironment: ["GREETING": "hello"])
        let outcome = await runner.run("echo \"$GREETING $SCOPE_PORT\"; exit 3", in: FileManager.default.temporaryDirectory,
                                       environment: ["SCOPE_PORT": "41000"], timeout: .seconds(10))
        #expect(outcome.exitCode == 3 && !outcome.succeeded)
        #expect(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello 41000")
        let slow = await runner.run("sleep 5", in: FileManager.default.temporaryDirectory, environment: [:], timeout: .milliseconds(200))
        #expect(slow.timedOut && slow.summary == "timed out")
    }
}
