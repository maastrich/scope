import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// Every secret here is made up, and assembled at run time so that no scanner takes the file for a leak.
@Suite(.serialized) struct SetupFailureTests {
    private let secret = "s3cr" + String(repeating: "Zx9Qk4Tm", count: 4)

    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    /// What uv prints when a private index refuses an expired token.
    private var refused: String {
        """
        uv pip install --index-url https://deploy:\(secret)@pkgs.acme.dev/simple -r requirements.txt
        error: Failed to fetch: `https://deploy:\(secret)@pkgs.acme.dev/simple/acme-core/`
          Caused by: HTTP status client error (401 Unauthorized) for url (https://deploy:\(secret)@pkgs.acme.dev/simple/acme-core/)
        make: *** [install] Error 2
        """
    }

    // MARK: (a) only the command that failed

    @Test func aStatusPrintedByARepositoryThatSucceededIsNotTheCause() {
        let log = """
        [api] $ make install
        warning: registry answered 401 Unauthorized once, retried with the keyring
        [api] done
        [web] $ pnpm install
        ERR_PNPM_OUTDATED_LOCKFILE  Cannot install with "frozen-lockfile"
        [web] failed: exit 1
        """
        #expect(ProblemCause.classify(log) == .auth)
        let diagnosis = SetupDiagnosis(log: log)
        #expect(diagnosis.failures.map(\.repo) == ["web"])
        #expect(diagnosis.failures.first?.command == "pnpm install")
        #expect(diagnosis.cause == .exit)
    }

    /// 18/11: one task journaled `auth` for its setup and `conflict` for the problem, the first read from the whole
    /// log and the second from its tail.
    @Test func theJournalAndTheProblemReadTheSameCause() {
        let filler = (1...80).map { "resolving package \($0)" }.joined(separator: "\n")
        let log = """
        [api] $ make install
        \(refused)
        [api] failed: exit 2
        [web] $ pnpm install
        \(filler)
        CONFLICT (content): Merge conflict in pnpm-lock.yaml was already resolved upstream
        [web] done
        """
        #expect(ProblemCause.classify(SetupLog.tail(log, lines: 60)) == .conflict)
        let diagnosis = SetupDiagnosis(log: log)
        #expect(diagnosis.cause == .auth)
        #expect(diagnosis.primary?.repo == "api")
    }

    @Test func everyFailedCommandIsReadOnItsOwn() {
        let log = """
        [api] copied .env from the base checkout
        [api] $ make install
        zsh: command not found: uv
        [api] failed: exit 127
        [billing] skipped `uv sync`: pyproject.toml has no [project] table. Fix the Setup field of the repository's graph card.
        [web@fix-login] $ pnpm install
        \(refused)
        [web@fix-login] failed: exit 2
        [docs] $ sleep 9999
        [docs] failed: timed out
        """
        let failures = SetupLog.failures(in: log)
        #expect(failures.map(\.repo) == ["api", "web@fix-login", "docs"])
        #expect(failures.map(\.cause) == [.notFound, .auth, .timeout])
        #expect(failures[0].line == "zsh: command not found: uv")
        #expect(failures[2].line == nil)
        // The refusal is the one the user can act on: it names the setup's cause and opens the detail.
        let diagnosis = SetupDiagnosis(log: log)
        #expect(diagnosis.cause == .auth)
        #expect(diagnosis.detail.hasPrefix("web@fix-login: pkgs.acme.dev answered 401 Unauthorized to `pnpm install`."))
    }

    @Test func outputShapedLikeAnEndDoesNotCloseTheCommand() {
        let log = """
        [api] $ make install
        [web] done
        [web] failed: exit 9
        npm ERR! 403 Forbidden - GET https://npm.acme.dev/@acme%2fui
        [api] failed: exit 1
        """
        let failures = SetupLog.failures(in: log)
        #expect(failures.count == 1)
        #expect(failures.first?.repo == "api")
        #expect(failures.first?.status == 403)
        #expect(failures.first?.host == "npm.acme.dev")
    }

    @Test func aLogCutAboveItsHeaderStillSaysWhatFailed() {
        let log = "[… earlier output dropped …]\n" + refused + "\n[api] failed: exit 2\n"
        let failure = SetupLog.failures(in: log).first
        #expect(failure?.repo == "api")
        #expect(failure?.command == nil)
        #expect(failure?.cause == .auth)
        #expect(failure?.headline == "api: pkgs.acme.dev answered 401 Unauthorized to the setup command.")
    }

    @Test func aSetupWithNoFailedCommandIsReadByItsEnd() {
        let log = "[api] $ make install\nResolved 12 packages\n[interrupted: Scope quit while the setup was running]\n"
        let diagnosis = SetupDiagnosis(log: log)
        #expect(diagnosis.failures.isEmpty)
        #expect(diagnosis.cause == .unknown)
        #expect(diagnosis.detail == SetupLog.tail(log, lines: 60))
        #expect(SetupDiagnosis(log: "").cause == .unknown)
    }

    // MARK: (b) the line that carries the cause, then the action

    @Test func aRefusalOpensOnTheHostTheStatusAndWhatToDo() {
        let failure = SetupFailure(repo: "api", command: "make install", summary: "exit 2", output: refused)
        #expect(failure.cause == .auth)
        #expect(failure.host == "pkgs.acme.dev")
        #expect(failure.status == 401)
        #expect(failure.line == "Caused by: HTTP status client error (401 Unauthorized) for url (https://deploy:***@pkgs.acme.dev/simple/acme-core/)")
        let lines = failure.explanation.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "api: pkgs.acme.dev answered 401 Unauthorized to `make install`.")
        #expect(lines[1] == "  " + (failure.line ?? ""))
        #expect(lines[2].contains("Refresh the login of pkgs.acme.dev"))
        #expect(lines[2].contains("run the setup again"))
    }

    @Test func theHostIsReadFromTheLineBesideTheStatus() {
        let pip = """
        Looking in indexes: https://pkgs.acme.dev/simple
        ERROR: HTTP error 401 while getting acme-core
        """
        let failure = SetupFailure(repo: "api", command: "pip install -r requirements.txt", summary: "exit 1", output: pip)
        #expect(failure.line == "ERROR: HTTP error 401 while getting acme-core")
        #expect(failure.host == "pkgs.acme.dev")

        let npm = "npm ERR! code E401\nnpm ERR! 401 Unauthorized - GET https://npm.pkg.github.com/@acme%2fui - authentication token not provided"
        #expect(SetupFailure(repo: "web", command: "npm ci", summary: "exit 1", output: npm).host == "npm.pkg.github.com")

        let bare = SetupFailure(repo: "web", command: "npm ci", summary: "exit 1", output: "error: not logged in")
        #expect(bare.host == nil && bare.status == nil)
        #expect(bare.headline == "web: `npm ci` was refused its credentials.")
        #expect(bare.action?.contains("Refresh the registry login") == true)
    }

    @Test func anotherCauseSaysWhatFailedAndPromisesNoFix() {
        let failure = SetupFailure(repo: "web", command: "pnpm install", summary: "exit 127", output: "zsh: command not found: pnpm")
        #expect(failure.cause == .notFound)
        #expect(failure.action == nil)
        #expect(failure.explanation == "web: `pnpm install` failed (exit 127).\n  zsh: command not found: pnpm")
        let silent = SetupFailure(repo: "web", command: "false", summary: "exit 1", output: "")
        #expect(silent.cause == .exit && silent.line == nil)
        #expect(silent.explanation == "web: `false` failed (exit 1).")
    }

    @Test func noTokenReachesTheMessage() {
        let log = "[api] $ make install TOKEN=https://deploy:\(secret)@pkgs.acme.dev/simple\n\(refused)\n[api] failed: exit 2\n"
        let diagnosis = SetupDiagnosis(log: log)
        #expect(!diagnosis.detail.contains(secret))
        #expect(diagnosis.detail.contains("https://deploy:***@pkgs.acme.dev"))
        let failure = SetupFailure(repo: "api", command: "make install TOKEN=https://deploy:\(secret)@pkgs.acme.dev/simple",
                                   summary: "exit 2", output: refused)
        #expect(!failure.explanation.contains(secret))
        var memory = SetupMemory()
        memory.record(failure, key: "/x/api", task: "Auth")
        let data = try? JSONStore.makeEncoder().encode(memory)
        #expect(data.map { String(decoding: $0, as: UTF8.self).contains(secret) } == false)
        // An entry built by hand is masked as well.
        let entry = SetupMemory.Entry(cause: .auth, line: "Authorization: Bearer \(secret)", failedAt: .now, task: "Auth")
        #expect(entry.line == "Authorization: Bearer ***")
    }

    // MARK: (c) remembered per repository

    @Test func aRefusalIsRememberedUntilTheRepositorySetsUpAgain() throws {
        let failure = SetupFailure(repo: "api", command: "make install", summary: "exit 2", output: refused)
        let key = SetupMemory.key(scopeRoot: "/work/acme", repo: "api")
        #expect(key == "/work/acme/api")
        #expect(SetupMemory.key(scopeRoot: "/work/acme", repo: ".") == "/work/acme")
        // Noon, so that the hours added below stay on the same day in any time zone.
        let monday = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)))
        var memory = SetupMemory()
        memory.record(failure, key: key, task: "Auth", at: monday)
        memory.record(failure, key: key, task: "Billing", at: monday.addingTimeInterval(3600))

        let reminders = memory.reminders(scopeRoot: "/work/acme", repos: ["web", "./api/"], now: monday.addingTimeInterval(5 * 86400))
        #expect(reminders.map(\.repo) == ["api"])
        #expect(reminders.first?.summary == "Last setup of api failed 5 days ago, 2 times in a row: pkgs.acme.dev refused the credentials (401).")
        #expect(reminders.first?.detail.contains("Unless the login of pkgs.acme.dev was refreshed since") == true)
        #expect(reminders.first?.detail.contains("(401 Unauthorized)") == true)
        #expect(memory.reminders(scopeRoot: "/work/acme", repos: ["api"], now: monday.addingTimeInterval(7200)).first?.age == "today")
        // Another scope's `api` is another repository.
        #expect(memory.reminders(scopeRoot: "/work/other", repos: ["api"]).isEmpty)

        memory.record(nil, key: key, task: "Auth")
        #expect(memory.reminders(scopeRoot: "/work/acme", repos: ["api"]).isEmpty)
    }

    @Test func onlyARefusalIsSaidAgain() {
        var memory = SetupMemory()
        let key = SetupMemory.key(scopeRoot: "/work/acme", repo: "web")
        memory.record(SetupFailure(repo: "web", command: "pnpm install", summary: "exit 127", output: "zsh: command not found: pnpm"),
                      key: key, task: "Auth")
        #expect(memory.repos[key]?.cause == .notFound)
        #expect(memory.reminders(scopeRoot: "/work/acme", repos: ["web"]).isEmpty)
        // A new cause starts its own count.
        memory.record(SetupFailure(repo: "web", command: "pnpm install", summary: "exit 1", output: "npm ERR! 401 Unauthorized"),
                      key: key, task: "Auth")
        #expect(memory.repos[key]?.count == 1)
        #expect(memory.reminders(scopeRoot: "/work/acme", repos: ["web"]).count == 1)
    }

    @Test func theMemoryRoundTripsThroughItsFileAndIgnoresAnotherVersion() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-setup-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = SetupMemoryStore(home: home)
        #expect(store.url.lastPathComponent == "setup-memory.json")
        #expect(store.load() == SetupMemory())
        var memory = SetupMemory()
        memory.record(SetupFailure(repo: "api", command: "make install", summary: "exit 2", output: refused), key: "/work/acme/api",
                      task: "Auth", at: Date(timeIntervalSince1970: 1_794_000_000))
        store.save(memory)
        #expect(store.load() == memory)
        memory.version = 99
        store.save(memory)
        #expect(store.load() == SetupMemory())
    }

    /// The whole path: a setup refused in one task is said before the setup of the next, and forgotten once the
    /// repository sets up.
    @Test func aNewTaskHearsOfTheLastRefusalBeforeItsSetupRuns() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        try await scope.makeRepo("web")
        let manager = makeManager(scope)
        let first = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api", "web"])
        let output = refused
        let failing = RecordingRunner { command in
            command == "fetch-deps" ? CommandOutcome(exitCode: 2, output: output) : CommandOutcome(exitCode: 0, output: "ok")
        }
        // Commands no file of the repositories rules out (`SetupCommandCheck`).
        let commands = ["api": SandboxCommands(setup: "fetch-deps"), "web": SandboxCommands(setup: "prepare-web")]
        let failed = try await manager.runSetup(first.id, commands: commands, runCommands: true, runner: failing)
        #expect(failed.setupState == .failed)
        #expect(SetupDiagnosis(log: failed.setup?.log ?? "").cause == .auth)

        let root = scope.declaration.path
        let reminders = await manager.setupReminders(scopeRoot: root, repos: ["api", "web"])
        #expect(reminders.map(\.repo) == ["api"])
        #expect(reminders.first?.entry.host == "pkgs.acme.dev")
        #expect(reminders.first?.entry.task == "Auth")
        #expect(try !String(contentsOf: ScopeHome.setupMemoryURL(home: scope.home), encoding: .utf8).contains(secret))
        // Another manager on the same home reads it: the memory outlives the app.
        #expect(await makeManager(scope).setupReminders(scopeRoot: root, repos: ["api"]).count == 1)

        // Copying the files without running the commands says nothing about the registry.
        try await manager.runSetup(first.id, commands: commands, runCommands: false, runner: failing)
        #expect(await manager.setupReminders(scopeRoot: root, repos: ["api"]).count == 1)

        let second = try await manager.create(name: "Billing", branch: "feat/billing", in: scope.declaration, repos: ["api"])
        try await manager.runSetup(second.id, commands: commands, runCommands: true, runner: failing)
        #expect(await manager.setupReminders(scopeRoot: root, repos: ["api"]).first?.entry.count == 2)

        try await manager.runSetup(second.id, commands: commands, runCommands: true, runner: RecordingRunner())
        #expect(await manager.setupReminders(scopeRoot: root, repos: ["api", "web"]).isEmpty)
    }
}
