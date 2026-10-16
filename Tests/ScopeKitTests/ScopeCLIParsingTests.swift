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

    @Test func configGetsAndSetsOneKey() throws {
        #expect(try Self.call(["config", "get"]) == .configGet(ConfigGetParams()))
        #expect(try Self.call(["config", "get", "automation.maxAgentTasks"]) == .configGet(ConfigGetParams(key: "automation.maxAgentTasks")))
        #expect(try Self.call(["config", "set", "automation.maxAgentThreads", "30"])
            == .configSet(ConfigSetParams(key: "automation.maxAgentThreads", value: "30")))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["config", "set", "automation.maxAgentThreads"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["config"]) }
    }

    @Test func taskNewTakesAPullRequestToStartFrom() throws {
        #expect(try Self.call(["task", "new", "review it", "--pr", "#42"]) == .taskNew(TaskNewParams(prompt: "review it", startPR: "#42")))
        #expect(try Self.call(["task", "new", "review it", "--pr=42"]) == .taskNew(TaskNewParams(prompt: "review it", startPR: "42")))
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

    @Test func archiveAndGarbageCollection() throws {
        #expect(try Self.call(["task", "archive", "rework-auth"]) == .taskArchive(TaskArchiveParams(task: "rework-auth")))
        #expect(throws: ScopeCLI.UsageError.self) { try Self.call(["task", "archive"]) }
        #expect(try Self.call(["gc"]) == .gc(GCParams()))
        #expect(try Self.call(["gc", "--dry-run"]) == .gc(GCParams(dryRun: true)))
        // An older script's --force still parses; there is nothing left for it to force.
        #expect(try Self.call(["task", "close", "t", "--force"]) == .taskClose(TaskCloseParams(task: "t")))
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

    /// The socket a client talks to: a flag, then what Scope injected into the thread, then the home.
    @Test func theEndpointFollowsTheFlagThenTheEnvironment() {
        #expect(ControlEndpoint.resolve(socket: "/tmp/explicit.sock", home: "/tmp/home",
                                        environment: ["SCOPE_SOCK": "/tmp/env.sock"]) == "/tmp/explicit.sock")
        #expect(ControlEndpoint.resolve(environment: ["SCOPE_SOCK": "/tmp/env.sock"]) == "/tmp/env.sock")
        #expect(ControlEndpoint.resolve(home: "/tmp/home", environment: [:]) == "/tmp/home/scope.sock")
        #expect(ControlEndpoint.resolve(environment: ["SCOPE_HOME": "/tmp/from-env"]) == "/tmp/from-env/scope.sock")
    }

    /// What a thread of the installed app hands every process it starts.
    private static let releaseThread = [
        "SCOPE_HOME": "/Users/me/.scope", "SCOPE_SOCK": "/Users/me/.scope/scope.sock", "SCOPE_THREAD": "8a18d7476063",
    ]

    /// `scope mcp --home ~/.scope-debug`, the Debug build's MCP entry, started by an agent running in a thread of
    /// the installed app: it must reach the Debug build, not the socket it inherited.
    @Test func anExplicitHomeBeatsTheInheritedSocket() {
        #expect(ControlEndpoint.resolve(home: "/Users/me/.scope-debug", environment: Self.releaseThread)
            == "/Users/me/.scope-debug/scope.sock")
        // …and the other way round: the installed app's entry, from a thread of a Debug build.
        let debugThread = ["SCOPE_HOME": "/Users/me/.scope-debug", "SCOPE_SOCK": "/Users/me/.scope-debug/scope.sock"]
        #expect(ControlEndpoint.resolve(home: "/Users/me/.scope", environment: debugThread) == "/Users/me/.scope/scope.sock")
    }

    /// Without a flag, a thread's CLI talks to the app that opened the thread — whichever build that is, and
    /// whatever else is running.
    @Test func aThreadTalksToTheAppThatOpenedIt() {
        #expect(ControlEndpoint.resolve(environment: Self.releaseThread) == "/Users/me/.scope/scope.sock")
        // `SCOPE_SOCK` is the app's word on where it listens (it may be the `$TMPDIR` fallback of a deep home),
        // so it outranks a socket re-derived from `SCOPE_HOME`.
        let deep = ["SCOPE_HOME": "/Users/me/.scope", "SCOPE_SOCK": "/var/folders/x/T/scope-501-0badcafe.sock"]
        #expect(ControlEndpoint.resolve(environment: deep) == "/var/folders/x/T/scope-501-0badcafe.sock")
    }

    /// `scope` and `scope mcp` parse the same options, so the two cannot disagree on the socket.
    @Test func theCLIAndTheMCPServerResolveTheSameEndpoint() throws {
        guard case .mcp(let mcp) = try ScopeCLI.parse(["mcp", "--home", "/Users/me/.scope-debug"]),
              case .call(_, let cli) = try ScopeCLI.parse(["list", "--home", "/Users/me/.scope-debug"]) else {
            Issue.record("both forms take --home")
            return
        }
        let fromMCP = ControlEndpoint.resolve(socket: mcp.socket, home: mcp.home, environment: Self.releaseThread)
        let fromCLI = ControlEndpoint.resolve(socket: cli.socket, home: cli.home, environment: Self.releaseThread)
        #expect(fromMCP == fromCLI)
        #expect(fromMCP == "/Users/me/.scope-debug/scope.sock")
    }

    /// The hint names a flag: inside a thread `SCOPE_HOME=` would lose to the inherited `SCOPE_SOCK`.
    @Test func theDebugHintNamesTheFlag() throws {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let debugSocket = userHome.appending(path: ".scope-debug/scope.sock").path
        final class Exists: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool { path.hasSuffix(".scope-debug/scope.sock") }
        }
        let hint = try #require(ControlEndpoint.hint(for: "/Users/me/.scope/scope.sock", environment: Self.releaseThread,
                                                     fileManager: Exists()))
        #expect(hint.contains("--home \(userHome.appending(path: ".scope-debug").path)"))
        #expect(!hint.contains("SCOPE_HOME="))
        // Asking the Debug socket itself gets no hint about itself.
        #expect(ControlEndpoint.hint(for: debugSocket, environment: [:], fileManager: Exists()) == nil)
    }

    @Test func summaryTakesThePeriodInPlainWords() throws {
        #expect(try Self.call(["summary"]) == .summary(SummaryParams()))
        #expect(try Self.call(["summary", "last", "week"]) == .summary(SummaryParams(period: "last week")))
        #expect(try Self.call(["summary", "2026-10-01..2026-10-14", "--scope", "acme"])
            == .summary(SummaryParams(period: "2026-10-01..2026-10-14", scope: "acme")))
        #expect(try Self.call(["summary", "--task", "auth-refresh"]) == .summary(SummaryParams(task: "auth-refresh")))
        #expect(try Self.options(["summary", "yesterday", "--json"]).json)
    }

    @Test func usageTakesAPeriodAnAreaAndALimit() throws {
        #expect(try Self.call(["usage"]) == .usage(UsageParams()))
        #expect(try Self.call(["usage", "last", "week", "--area", "sidebar", "--limit", "5"])
            == .usage(UsageParams(period: "last week", area: "sidebar", limit: 5)))
        #expect(try Self.options(["usage", "--json"]).json)
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["usage", "someday"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["usage", "--limit", "0"]) }
    }

    @Test func summaryRefusesAPeriodItCannotRead() {
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["summary", "someday"]) }
    }
}
