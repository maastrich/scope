import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// Real git, real worktrees: the hooks are shell scripts, so only running them says anything.
@Suite(.serialized) struct SandboxGitHooksTests {
    struct Run {
        var status: Int32
        var output: String
        var succeeded: Bool { status == 0 }
    }

    /// A task root holding one sandbox of `acme/api`, the hooks installed, and the environment a task thread gets.
    struct Fixture {
        let scope: TestScope
        let repo: URL
        let taskRoot: URL
        let sandbox: URL
        let environment: [String: String]

        static func make(prepare: ((TestScope, URL) async throws -> Void)? = nil) async throws -> Fixture {
            let scope = try await TestScope.make()
            let repo = try await scope.makeRepo("api")
            try await prepare?(scope, repo)
            let taskRoot = scope.root.appending(path: "sandboxes/acme/t1", directoryHint: .isDirectory)
            let sandbox = taskRoot.appending(path: "api", directoryHint: .isDirectory)
            let client = await scope.client(for: repo)
            try await client.createWorktree(at: sandbox, branch: "scope/t1", from: "origin/main")
            let hooks = try SandboxGitHooks.install(home: scope.home)
            var environment = SandboxGitHooks.environment(adding: hooks.path, to: scope.environment)
            environment["SCOPE_TASK_ROOT"] = taskRoot.path
            environment["PATH"] = "/usr/bin:/bin"
            return Fixture(scope: scope, repo: repo, taskRoot: taskRoot, sandbox: sandbox, environment: environment)
        }

        @discardableResult
        func git(_ arguments: [String], in directory: URL, environment: [String: String]? = nil) throws -> Run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scope.gitPath)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment ?? self.environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }

        func commitAll(in directory: URL, _ message: String) throws -> Run {
            try git(["add", "-A"], in: directory)
            return try git(["commit", "-q", "-m", message], in: directory)
        }
    }

    static func hook(_ body: String) -> String { "#!/bin/sh\n\(body)\n" }

    static func writeExecutable(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func aCommitInTheSandboxGoesThrough() async throws {
        let fixture = try await Fixture.make()
        try fixture.scope.write(fixture.sandbox, "a.txt", "a\n")
        let run = try fixture.commitAll(in: fixture.sandbox, "work")
        #expect(run.succeeded, "\(run.output)")
    }

    @Test func aCommitInTheBaseCheckoutIsRefused() async throws {
        let fixture = try await Fixture.make()
        try fixture.scope.write(fixture.repo, "b.txt", "b\n")
        let run = try fixture.commitAll(in: fixture.repo, "oops")
        #expect(!run.succeeded)
        #expect(run.output.contains("scope: refusing to commit"), "\(run.output)")
        #expect(run.output.contains(fixture.sandbox.lastPathComponent))
        // Without the task environment (the user's own terminal) nothing is enforced.
        var userEnvironment = fixture.scope.environment
        userEnvironment["PATH"] = "/usr/bin:/bin"
        #expect(try fixture.git(["commit", "-q", "-m", "mine"], in: fixture.repo, environment: userEnvironment).succeeded)
    }

    @Test func aCommitInAnUnrelatedRepositoryIsLeftAlone() async throws {
        let fixture = try await Fixture.make()
        let other = try await fixture.scope.makeRepo("web", withOrigin: false)
        try fixture.scope.write(other, "c.txt", "c\n")
        let run = try fixture.commitAll(in: other, "elsewhere")
        #expect(run.succeeded, "\(run.output)")
    }

    @Test func aPushOntoTheDefaultBranchIsRefusedAndTheTaskBranchGoesThrough() async throws {
        let fixture = try await Fixture.make()
        try fixture.scope.write(fixture.sandbox, "d.txt", "d\n")
        #expect(try fixture.commitAll(in: fixture.sandbox, "work").succeeded)
        let toMain = try fixture.git(["push", "-q", "origin", "HEAD:main"], in: fixture.sandbox)
        #expect(!toMain.succeeded)
        #expect(toMain.output.contains("scope: refusing to push to main"), "\(toMain.output)")
        let toBranch = try fixture.git(["push", "-q", "origin", "HEAD:scope/t1"], in: fixture.sandbox)
        #expect(toBranch.succeeded, "\(toBranch.output)")
    }

    @Test func theRepositorysOwnHooksStillRun() async throws {
        let fixture = try await Fixture.make()
        let marker = fixture.scope.root.appending(path: "own-hook-ran", directoryHint: .notDirectory)
        // lefthook / pre-commit style: in the shared `.git/hooks`.
        try Self.writeExecutable(fixture.repo.appending(path: ".git/hooks/pre-commit"), Self.hook("echo pre-commit >> '\(marker.path)'"))
        // pre-push reads its refs from stdin, which Scope read first: it must be handed over intact.
        try Self.writeExecutable(fixture.repo.appending(path: ".git/hooks/pre-push"), Self.hook("cat >> '\(marker.path)'"))
        try fixture.scope.write(fixture.sandbox, "e.txt", "e\n")
        #expect(try fixture.commitAll(in: fixture.sandbox, "work").succeeded)
        #expect(try fixture.git(["push", "-q", "origin", "HEAD:scope/t1"], in: fixture.sandbox).succeeded)
        let log = try String(contentsOf: marker, encoding: .utf8)
        #expect(log.contains("pre-commit"))
        #expect(log.contains("refs/heads/scope/t1"), "\(log)")
    }

    @Test func aHuskyStyleRelativeHooksPathIsFollowed() async throws {
        let fixture = try await Fixture.make { scope, repo in
            let client = await scope.client(for: repo)
            try await client.run(["config", "core.hooksPath", ".husky/_"])
        }
        let marker = fixture.scope.root.appending(path: "husky-ran", directoryHint: .notDirectory)
        // Relative to the sandbox's own working tree, like husky's generated folder after `npm install`.
        try Self.writeExecutable(fixture.sandbox.appending(path: ".husky/_/commit-msg"), Self.hook("echo commit-msg >> '\(marker.path)'"))
        try fixture.scope.write(fixture.sandbox, "f.txt", "f\n")
        #expect(try fixture.commitAll(in: fixture.sandbox, "work").succeeded)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func theOverrideIsAppendedToTheUsersOwnGitConfigEnvironment() {
        let base = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Me", "PATH": "/bin"]
        let result = SandboxGitHooks.environment(adding: "/h/githooks", to: base)
        #expect(result["GIT_CONFIG_COUNT"] == "2")
        #expect(result["GIT_CONFIG_KEY_0"] == "user.name")
        #expect(result["GIT_CONFIG_KEY_1"] == "core.hooksPath")
        #expect(result["GIT_CONFIG_VALUE_1"] == "/h/githooks")
        #expect(SandboxGitHooks.environment(adding: "/h/githooks", to: result) == result)
        #expect(SandboxGitHooks.environment(adding: "/h/githooks", to: [:])["GIT_CONFIG_COUNT"] == "1")
    }

    @Test func installIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-githooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try SandboxGitHooks.install(home: home)
        let second = try SandboxGitHooks.install(home: home)
        #expect(first == second)
        for name in SandboxGitHooks.hookNames {
            let link = first.appending(path: name).path
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == SandboxGitHooks.dispatcherName)
        }
        #expect(FileManager.default.isExecutableFile(atPath: first.appending(path: SandboxGitHooks.dispatcherName).path))
    }

    /// An app started from a thread of another Scope inherits that thread's variables and its hooks override;
    /// neither may reach its own git calls or the threads it opens.
    @Test func anInheritedThreadLeavesNothingBehind() throws {
        let otherHome = FileManager.default.temporaryDirectory.appending(path: "other-scope-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: otherHome) }
        let otherHooks = try SandboxGitHooks.install(home: otherHome).path

        let inherited = [
            "PATH": "/usr/bin", "EDITOR": "vim",
            "SCOPE_HOME": otherHome.path, "SCOPE_SOCK": otherHome.path + "/scope.sock", "SCOPE_THREAD": "8a18d7476063",
            "SCOPE_TASK": "demo", "SCOPE_TASK_ROOT": otherHome.path + "/sandboxes/acme/demo", "SCOPE_PORT": "41020",
            "SCOPE_SCOPE": "acme", "SCOPE_SCOPE_ROOT": "/Users/me/acme",
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Me",
            "GIT_CONFIG_KEY_1": "core.hooksPath", "GIT_CONFIG_VALUE_1": otherHooks,
            "GIT_CONFIG_KEY_2": "commit.gpgsign", "GIT_CONFIG_VALUE_2": "false",
        ]
        let clean = SandboxGitHooks.withoutInheritedThread(inherited)
        #expect(clean == [
            "PATH": "/usr/bin", "EDITOR": "vim",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Me",
            "GIT_CONFIG_KEY_1": "commit.gpgsign", "GIT_CONFIG_VALUE_1": "false",
        ])
        #expect(!clean.keys.contains { $0.hasPrefix("SCOPE_") })
    }

    @Test func onlyAScopeHooksOverrideIsRemoved() throws {
        // The only entry was Scope's: no GIT_CONFIG_* is left at all.
        let gone = SandboxGitHooks.environment(removingScopeHooksFrom: [
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": "/Users/me/.scope/githooks",
        ])
        #expect(gone.isEmpty)

        // A hooks path of the user's own is theirs, whatever it is called.
        let home = FileManager.default.temporaryDirectory.appending(path: "user-hooks-\(UUID().uuidString.prefix(6))")
        let own = home.appending(path: "githooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [own.path, "/Users/me/dotfiles/hooks"] {
            let theirs = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": path, "LANG": "C"]
            #expect(SandboxGitHooks.environment(removingScopeHooksFrom: theirs) == theirs)
        }
        #expect(SandboxGitHooks.environment(removingScopeHooksFrom: ["LANG": "C"]) == ["LANG": "C"])
    }
}
