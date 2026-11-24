import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// Every secret here is made up, and assembled at run time so that no scanner takes the file for a leak.
@Suite(.serialized) struct SetupLogRedactTests {
    private static func fake(_ length: Int) -> String {
        String(String(repeating: "Zx9Qk4Tm", count: length / 8 + 1).prefix(length))
    }

    private let secret = "s3cr" + SetupLogRedactTests.fake(28)
    private let jwt = ["eyJ" + SetupLogRedactTests.fake(33), "eyJ" + SetupLogRedactTests.fake(40), SetupLogRedactTests.fake(43)]
        .joined(separator: ".")

    private func makeManager(_ scope: TestScope) -> TaskManager {
        TaskManager(home: scope.home, registry: scope.registry, store: TaskRecordStore(home: scope.home))
    }

    // MARK: URL userinfo

    @Test func aPackageIndexURLKeepsItsUserAndHost() {
        // What `make` echoes before running a Python repository's install.
        let pip = "pip install --index-url https://deploy:\(secret)@pypi.acme.dev/simple/ -r requirements.txt"
        #expect(SetupLog.redact(pip) == "pip install --index-url https://deploy:***@pypi.acme.dev/simple/ -r requirements.txt")

        let uv = """
        uv sync --extra-index-url=https://__token__:\(secret)@gitlab.acme.dev/api/v4/projects/12/packages/pypi/simple
        error: Failed to fetch: `https://__token__:\(secret)@gitlab.acme.dev/api/v4/projects/12/packages/pypi/simple/acme-core/`
          Caused by: HTTP status client error (401 Unauthorized)
        """
        let masked = SetupLog.redact(uv)
        #expect(!masked.contains(secret))
        #expect(masked.contains("https://__token__:***@gitlab.acme.dev/api/v4/projects/12/packages/pypi/simple/acme-core/`"))
        #expect(masked.contains("(401 Unauthorized)"))

        #expect(SetupLog.redact("UV_INDEX_URL=\"https://:\(secret)@pypi.acme.dev/simple\"") == "UV_INDEX_URL=\"https://:***@pypi.acme.dev/simple\"")
        #expect(SetupLog.redact("git clone https://x-access-token:\(secret)@github.com/acme/api.git")
            == "git clone https://x-access-token:***@github.com/acme/api.git")
        #expect(SetupLog.redact("DATABASE_URL=postgres://app:\(secret)@db.internal:5432/app") == "DATABASE_URL=postgres://app:***@db.internal:5432/app")
    }

    @Test func aTokenAloneInTheUserinfoIsMaskedAUserNameIsNot() {
        #expect(SetupLog.redact("https://\(secret)@pypi.fury.io/acme/") == "https://***@pypi.fury.io/acme/")
        #expect(SetupLog.redact("ssh://git@github.com/acme/api.git") == "ssh://git@github.com/acme/api.git")
    }

    @Test func whatHoldsNoCredentialIsLeftAlone() {
        let lines = [
            "Looking in indexes: https://pypi.org/simple, https://pypi.acme.dev/simple/",
            "curl http://localhost:3000/health",
            "GET http://localhost:3000/?to=dev@acme.dev 200",
            "http://127.0.0.1:8080/users/@me",
            "git@github.com:acme/api.git",
            "Author: Dev <dev@acme.dev>",
            "npm warn deprecated inflight@1.0.6: This module is not supported",
            "error: authorization failed for https://npm.acme.dev/ (the password is wrong?)",
            "eyJ is how a JWT starts; npm_config_cache=/tmp/cache; ghp_ is a prefix",
            "//registry.npmjs.org/:always-auth=true",
        ]
        for line in lines { #expect(SetupLog.redact(line) == line) }
        #expect(SetupLog.redact("") == "")
    }

    // MARK: Tokens

    @Test func jwtAndJweValuesAreMasked() {
        #expect(SetupLog.redact("CODEARTIFACT_AUTH_TOKEN=\(jwt) poetry install") == "CODEARTIFACT_AUTH_TOKEN=eyJ*** poetry install")
        // A JWE has five segments, and its encrypted key is empty under direct encryption.
        let jwe = "eyJ\(Self.fake(40))..\(Self.fake(16)).\(Self.fake(60)).\(Self.fake(22))"
        #expect(SetupLog.redact("token: \(jwe)\nnext line") == "token: eyJ***\nnext line")
    }

    @Test func gitHubAndNpmTokensKeepTheirPrefix() {
        let classic = "ghp_" + Self.fake(36)
        let oauth = "gho_" + Self.fake(36)
        let fine = "github_pat_" + Self.fake(22) + "_" + Self.fake(59)
        let npm = "npm_" + Self.fake(36)
        #expect(SetupLog.redact("GH_TOKEN=\(classic) gh api user") == "GH_TOKEN=ghp_*** gh api user")
        #expect(SetupLog.redact("token \(oauth), then \(fine).") == "token gho_***, then github_pat_***.")
        #expect(SetupLog.redact("NPM_TOKEN=\(npm)") == "NPM_TOKEN=npm_***")
    }

    @Test func npmrcAuthLinesAreMasked() {
        let npmrc = """
        @acme:registry=https://npm.acme.dev/
        //npm.acme.dev/:_authToken=\(secret)
        //registry.npmjs.org/:_authToken="\(secret)"
        //legacy.acme.dev/:_auth=\(Self.fake(24))==
        //legacy.acme.dev/:_password = \(Self.fake(24))
        """
        #expect(SetupLog.redact(npmrc) == """
        @acme:registry=https://npm.acme.dev/
        //npm.acme.dev/:_authToken=***
        //registry.npmjs.org/:_authToken="***"
        //legacy.acme.dev/:_auth=***
        //legacy.acme.dev/:_password = ***
        """)
    }

    @Test func authorizationHeadersAreMasked() {
        #expect(SetupLog.redact("> Authorization: Bearer \(secret)\n> Accept: */*") == "> Authorization: Bearer ***\n> Accept: */*")
        #expect(SetupLog.redact("curl -H 'authorization: token \(secret)' https://api.github.com/user")
            == "curl -H 'authorization: token ***' https://api.github.com/user")
        #expect(SetupLog.redact("-H \"Authorization: Basic \(Self.fake(24))==\"") == "-H \"Authorization: Basic ***\"")
        #expect(SetupLog.redact("sent Bearer \(secret) to npm.acme.dev") == "sent Bearer *** to npm.acme.dev")
        // A header cut at the end of a line does not eat the next one.
        #expect(SetupLog.redact("Authorization: Bearer\nnext") == "Authorization: Bearer\nnext")
    }

    @Test func netrcEntriesAreMasked() {
        #expect(SetupLog.redact("machine pypi.acme.dev login deploy password \(secret)") == "machine pypi.acme.dev login deploy password ***")
        let multiline = "machine npm.acme.dev\n  login deploy\n  password \(secret)\nmachine other"
        #expect(SetupLog.redact(multiline) == "machine npm.acme.dev\n  login deploy\n  password ***\nmachine other")
    }

    @Test func maskingTwiceChangesNothing() {
        let log = """
        [api] $ make install
        pip install --index-url https://deploy:\(secret)@pypi.acme.dev/simple/ -r requirements.txt
        https://\(secret)@pypi.fury.io/acme/
        //npm.acme.dev/:_authToken=\(secret)
        Authorization: Bearer \(jwt)
        machine pypi.acme.dev login deploy password \(secret)
        GH_TOKEN=\("ghp_" + Self.fake(36))
        [api] failed: exit 1
        """
        let once = SetupLog.redact(log)
        #expect(!once.contains(secret) && !once.contains(jwt))
        #expect(SetupLog.redact(once) == once)
        #expect(once.hasPrefix("[api] $ make install\n") && once.hasSuffix("[api] failed: exit 1"))
    }

    // MARK: Where it is applied

    @Test func aSetupRunWritesAMaskedLog() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let secret = self.secret
        let runner = RecordingRunner { _ in
            CommandOutcome(exitCode: 1, output: "pip install --index-url https://deploy:\(secret)@pypi.acme.dev/simple/\nERROR: 401")
        }
        let command = "PIP_INDEX_URL=https://deploy:\(secret)@pypi.acme.dev/simple/ make install"
        let done = try await manager.runSetup(task.id, commands: ["api": SandboxCommands(setup: command)], runCommands: true, runner: runner)
        let log = try #require(done.setup?.log)
        #expect(!log.contains(secret))
        #expect(log.contains("[api] $ PIP_INDEX_URL=https://deploy:***@pypi.acme.dev/simple/ make install\n"))
        #expect(log.contains("--index-url https://deploy:***@pypi.acme.dev/simple/\nERROR: 401\n[api] failed: exit 1"))
        // The command itself ran as written.
        #expect(runner.recorded.map(\.command) == [command])
        let onDisk = try String(contentsOf: TaskRecordStore(home: scope.home).url(for: task.id), encoding: .utf8)
        #expect(!onDisk.contains(secret))
    }

    @Test func aFailedTeardownReportsAMaskedLog() async throws {
        let scope = try await TestScope.make()
        try await scope.makeRepo("api")
        let manager = makeManager(scope)
        let task = try await manager.create(name: "Auth", branch: "feat/auth", in: scope.declaration, repos: ["api"])
        let secret = self.secret
        let failing = TaskManager.Teardown(commands: ["api": SandboxCommands(teardown: "make clean")], runner: RecordingRunner { _ in
            CommandOutcome(exitCode: 1, output: "curl -H 'Authorization: Bearer \(secret)' https://api.acme.dev/release")
        })
        let outcome = try await manager.dismantle(task.id, .archive, teardown: failing)
        guard case .teardownFailed(_, _, let log) = try #require(outcome.notices.first) else { return }
        #expect(!log.contains(secret) && log.contains("Authorization: Bearer ***' https://api.acme.dev/release"))
    }

    @Test func aRecordWrittenBeforeMaskingIsCleanedWhenLoadedAndSaved() async throws {
        let scope = try await TestScope.make()
        let store = TaskRecordStore(home: scope.home)
        var old = TaskRecord(scopeID: scope.declaration.id, scopeRoot: scope.scopeRoot.path, scopeSlug: "acme",
                             name: "Old", slug: "old", branch: "feat/old", root: scope.home.appending(path: "sandboxes/acme/old").path,
                             createdAt: TaskRecord.roundedToMilliseconds(.now))
        // A finished setup, on an archived task: neither the restart rule nor the port rule touches it.
        old.setup = TaskSetupRecord(state: .failed, log: "[api] $ make install\npip install -i https://deploy:\(secret)@pypi.acme.dev/simple/\n[api] failed: exit 1\n")
        old.archivedAt = TaskRecord.roundedToMilliseconds(.now)
        try await store.save(old)
        #expect(try String(contentsOf: store.url(for: old.id), encoding: .utf8).contains(secret))

        let manager = makeManager(scope)
        #expect(await manager.loadAll().isEmpty)
        let cleaned = try #require(await manager.task(old.id))
        #expect(cleaned.setup?.state == .failed)
        #expect(cleaned.setup?.log == "[api] $ make install\npip install -i https://deploy:***@pypi.acme.dev/simple/\n[api] failed: exit 1\n")
        // Rewritten at once: the secret is gone from the file, not only from memory.
        #expect(try !String(contentsOf: store.url(for: old.id), encoding: .utf8).contains(secret))
    }

    @Test func anInterruptedSetupIsMaskedToo() {
        let interrupted = TaskSetupRecord(state: .running, log: "//npm.acme.dev/:_authToken=\(secret)\n").normalizedAfterRestart
        #expect(interrupted.state == .failed)
        #expect(interrupted.log.hasPrefix("//npm.acme.dev/:_authToken=***\n") && interrupted.log.contains("interrupted"))
        let clean = TaskSetupRecord(state: .succeeded, log: "pnpm install\nDone in 4s\n")
        #expect(clean.normalizedAfterRestart == clean)
    }
}
