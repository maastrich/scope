import Foundation
import Testing
@testable import ScopeControl

/// What the `scope` binary makes of a command line — the CLI itself only plumbs the result through.
@Suite struct ScopeCLIParsingTests {
    static func call(_ arguments: [String]) throws -> ControlCall {
        guard case .call(let call, _) = try ScopeCLI.parse(arguments) else {
            throw ScopeCLI.UsageError(message: "not a call", usage: "")
        }
        return call
    }

    static func options(_ arguments: [String]) throws -> ScopeCLI.Options {
        guard case .call(_, let options) = try ScopeCLI.parse(arguments) else {
            throw ScopeCLI.UsageError(message: "not a call", usage: "")
        }
        return options
    }

    @Test func nothingIsHelp() throws {
        guard case .help = try ScopeCLI.parse([]) else {
            Issue.record("a bare `scope` should say what it can do")
            return
        }
    }

    @Test func listDefaultsToEverything() throws {
        #expect(try Self.call(["list"]) == .list(ListParams()))
        #expect(try Self.call(["list", "threads"]) == .list(ListParams(kind: .threads)))
        #expect(try Self.call(["list", "tasks", "--scope", "acme"]) == .list(ListParams(kind: .tasks, scope: "acme")))
    }

    @Test func anUnknownListKindIsRefused() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["list", "everything"]) }
    }

    @Test func threadNewTakesItsOptionsInEitherSpelling() throws {
        let expected = ControlCall.threadNew(ThreadNewParams(scope: "acme", driver: "claude-code", task: nil,
                                                             repo: "api", title: "CI", prompt: "why is it red?"))
        #expect(try Self.call(["thread", "new", "--scope", "acme", "--driver", "claude-code",
                               "--repo", "api", "--title", "CI", "-p", "why is it red?"]) == expected)
        #expect(try Self.call(["thread", "new", "--scope=acme", "--driver=claude-code",
                               "--repo=api", "--title=CI", "--prompt=why is it red?"]) == expected)
    }

    @Test func taskNewTakesItsPromptAsWords() throws {
        #expect(try Self.call(["task", "new", "fix", "the", "flaky", "login", "test"])
            == .taskNew(TaskNewParams(prompt: "fix the flaky login test")))
    }

    @Test func taskNewCollectsRepositoriesAndFlags() throws {
        let call = try Self.call(["task", "new", "rework auth", "--repo", "api", "--repo", "web",
                                  "--branch", "feat/auth", "--dry-run", "--no-thread"])
        guard case .taskNew(let params) = call else {
            Issue.record("that is a task")
            return
        }
        #expect(params.repos == ["api", "web"])
        #expect(params.branch == "feat/auth")
        #expect(params.dryRun)
        #expect(!params.openThread)
    }

    @Test func taskNewWithoutAPromptSaysWhy() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "new", "--repo", "api"]) }
    }

    @Test func sharedOptionsWorkAfterAnyCommand() throws {
        let options = try Self.options(["thread", "new", "--json", "--sock", "/tmp/s.sock", "--home", "/tmp/home"])
        #expect(options == ScopeCLI.Options(socket: "/tmp/s.sock", home: "/tmp/home", json: true))
    }

    @Test func aFlagWithoutItsValueIsAUsageError() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "new", "--scope"]) }
    }

    @Test func anUnknownOptionIsAUsageError() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["list", "--everything"]) }
    }

    @Test func unknownCommandsAndHalfCommands() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["teleport"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "list"]) }
    }

    @Test func mcpIsACommandOfItsOwn() throws {
        guard case .mcp(let options) = try ScopeCLI.parse(["mcp", "--home", "/tmp/home"]) else {
            Issue.record("`scope mcp` speaks MCP, it does not call one method")
            return
        }
        #expect(options.home == "/tmp/home")
    }

    @Test func helpAndVersionAreAnswersNotErrors() throws {
        guard case .help = try ScopeCLI.parse(["--help"]) else {
            Issue.record("--help prints the usage")
            return
        }
        guard case .version = try ScopeCLI.parse(["--version"]) else {
            Issue.record("--version prints the version")
            return
        }
    }

    /// The socket a client talks to: the flag, then what Scope injected into the thread, then the home.
    @Test func theEndpointFollowsTheFlagThenTheEnvironment() {
        #expect(ControlEndpoint.resolve(socket: "/tmp/explicit.sock", home: "/tmp/home",
                                        environment: ["SCOPE_SOCK": "/tmp/env.sock"]) == "/tmp/explicit.sock")
        #expect(ControlEndpoint.resolve(environment: ["SCOPE_SOCK": "/tmp/env.sock"]) == "/tmp/env.sock")
        #expect(ControlEndpoint.resolve(home: "/tmp/home", environment: [:]) == "/tmp/home/scope.sock")
        #expect(ControlEndpoint.resolve(environment: ["SCOPE_HOME": "/tmp/from-env"]) == "/tmp/from-env/scope.sock")
    }
}
