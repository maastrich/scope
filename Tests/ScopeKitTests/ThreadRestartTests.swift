import Foundation
import Testing
@testable import ScopeAdapters
import ScopeControl
@testable import ScopeDrivers

/// Restart Session: which threads may, the launch that follows the kill, the mid-turn question, the draft typed back,
/// and the control call that reaches it from the CLI and MCP.
@Suite struct ThreadRestartTests {
    static let claude = DriverProfile(id: "claude-code", name: "Claude Code", command: "claude",
                                      resume: ["claude", "--resume", "{resume_id}"], modelArgs: ["--model", "{model}"],
                                      adapter: .init(kind: ClaudeHooksAdapter.kind))
    static let shell = DriverProfile(id: "shell", name: "Shell", command: "$SHELL", loginShell: true)
    static let session = "4787d591-d8e9-4025-ba52-9e9c7fc76915"

    // MARK: Availability

    @Test func aClaudeThreadWithASessionMayRestart() {
        #expect(ThreadRestart.unavailable(profile: Self.claude, resumeID: Self.session) == nil)
    }

    @Test func noSessionIdYetDisablesItWithAReason() {
        #expect(ThreadRestart.unavailable(profile: Self.claude, resumeID: nil) == .noSession)
        #expect(ThreadRestart.unavailable(profile: Self.claude, resumeID: "") == .noSession)
        #expect(ThreadRestart.Unavailable.noSession.reason == "no Claude Code session yet")
    }

    @Test func otherDriversNeverRestart() {
        #expect(ThreadRestart.unavailable(profile: Self.shell, resumeID: Self.session) == .notClaude)
        let codex = DriverProfile(id: "codex", name: "Codex", command: "codex", resume: ["codex", "resume", "{resume_id}"])
        #expect(ThreadRestart.unavailable(profile: codex, resumeID: Self.session) == .notClaude)
        #expect(!ThreadRestart.isClaude(codex))
    }

    @Test func aClaudeProfileThatCannotResumeHasNoSessionToRestart() {
        let noResume = DriverProfile(id: "claude-custom", name: "Claude", command: "claude", adapter: .init(kind: ClaudeHooksAdapter.kind))
        #expect(ThreadRestart.unavailable(profile: noResume, resumeID: Self.session) == .noSession)
    }

    @Test func theBundledClaudeProfilesMayRestart() throws {
        for profile in try DriverRegistry.bundledProfiles() where ThreadRestart.isClaude(profile) {
            #expect(ThreadRestart.unavailable(profile: profile, resumeID: Self.session) == nil, "\(profile.id)")
        }
    }

    // MARK: The resume command

    @Test func theRestartResumesTheSameSessionOnTheSameModel() throws {
        #expect(ThreadRestart.resumeMode(profile: Self.claude, resumeID: Self.session) == .resume)
        let values = PlaceholderValues(threadID: "3f9a2c17be04", resumeID: Self.session, cwd: "/tmp", scope: "/tmp",
                                       home: "/tmp", model: "claude-opus-5-5")
        let shell = ResolvedShellEnvironment(shell: "/bin/zsh", variables: ["PATH": "/usr/bin:/bin"], source: .login)
        let scope = TerminalEnvironment.ScopeVariables(thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/tmp",
                                                       sock: "/tmp/scope.sock", home: "/tmp")
        var profile = Self.claude
        profile.command = "/bin/echo"
        profile.resume = ["/bin/echo", "--resume", "{resume_id}"]
        let plan = try LaunchPlanner.plan(profile: profile, mode: ThreadRestart.resumeMode(profile: profile, resumeID: Self.session),
                                          values: values, shellEnvironment: shell, scopeVariables: scope, appVersion: "0.1.0",
                                          adapterArguments: ["--settings", "/tmp/hooks.json"])
        #expect(plan.arguments == ["--resume", Self.session, "--model", "claude-opus-5-5", "--settings", "/tmp/hooks.json"])
        #expect(plan.cwd == "/tmp")
    }

    // MARK: Mid-turn

    @Test func aTurnInProgressIsInterrupted() {
        #expect(ThreadRestart.interruptsTurn(inTurn: true, working: true))
        // Waiting on a permission: nothing runs, the turn is still open.
        #expect(ThreadRestart.interruptsTurn(inTurn: true, working: false))
        #expect(ThreadRestart.interruptsTurn(inTurn: false, working: true))
        #expect(!ThreadRestart.interruptsTurn(inTurn: false, working: false))
    }

    @Test func theSelfRestartNoteIsNotTheAppRestartOne() {
        #expect(!ThreadRestart.selfRestartNote.contains("Scope restarted"))
    }

    // MARK: Draft

    static let nbsp = "\u{a0}"

    static func screen(columns: Int, _ field: [String], shell: Bool = false) -> [ScreenRow] {
        let rule = ScreenRow(String(repeating: "─", count: columns))
        let glyph = shell ? "!" : "❯"
        let rows = field.enumerated().map { index, line in ScreenRow(index == 0 ? "\(glyph)\(nbsp)\(line)" : "  \(line)") }
        return [ScreenRow("⏺ done"), rule] + rows + [rule, ScreenRow("  ⏵⏵ auto mode on")]
    }

    @Test func aLongLineClaudeWrappedComesBackAsOne() throws {
        // 40 columns: 36 for the text. "jumps" (5) cannot follow a 32-character row.
        let rows = Self.screen(columns: 40, ["the quick brown fox and the lazy", "jumps over"])
        let draft = try #require(ClaudeDraft.retype(rows, columns: 40))
        #expect(draft.text == "the quick brown fox and the lazy jumps over")
        #expect(draft.mode == .prompt)
    }

    @Test func aLineBreakTheUserTypedStays() throws {
        let rows = Self.screen(columns: 40, ["first line", "second line"])
        #expect(try #require(ClaudeDraft.retype(rows, columns: 40)).text == "first line\nsecond line")
    }

    @Test func pastedBlocksAndImagesAreLeftOut() throws {
        let rows = Self.screen(columns: 100, ["look at [Image #1] and [Pasted text #2 +15 lines] please"])
        let draft = try #require(ClaudeDraft.retype(rows, columns: 100))
        #expect(draft.droppedAttachments == 2)
        #expect(!draft.text.contains("["))
        #expect(draft.text.hasPrefix("look at"))
    }

    @Test func anEmptyFieldHasNothingToRetype() {
        let rule = ScreenRow(String(repeating: "─", count: 60))
        let rows = [rule, ScreenRow("❯\(Self.nbsp)Try \"fix lint errors\"", dimFrom: 2), rule]
        #expect(ClaudeDraft.retype(rows, columns: 60) == nil)
    }

    @Test func shellModeIsKept() throws {
        let draft = try #require(ClaudeDraft.retype(Self.screen(columns: 60, ["git status"], shell: true), columns: 60))
        #expect(draft == ClaudeDraft.Retype(mode: .shell, text: "git status"))
    }

    // MARK: Control

    @Test func theCLIAndMCPReachTheSameCall() throws {
        guard case .call(let call, _) = try ScopeCLI.parse(["thread", "restart", "3f9a2c17be04"]) else {
            Issue.record("not a call")
            return
        }
        #expect(call == .threadRestart(ThreadRestartParams(thread: "3f9a2c17be04")))
        guard case .call(let forced, _) = try ScopeCLI.parse(["thread", "restart", "3f9a2c17be04", "--force"]) else {
            Issue.record("not a call")
            return
        }
        #expect(forced == .threadRestart(ThreadRestartParams(thread: "3f9a2c17be04", force: true)))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "restart"]) }

        let mcp = MCPBridge.call(tool: "scope_thread_restart", arguments: Data(#"{"id":"3f9a2c17be04","force":true}"#.utf8))
        #expect(mcp == .success(.threadRestart(ThreadRestartParams(thread: "3f9a2c17be04", force: true))))
    }

    @Test func theCallRoundTripsAndForceDefaultsToFalse() throws {
        let caller = ControlCaller(client: "scope-cli/test")
        let request = ControlRequest(id: "1", caller: caller, call: .threadRestart(ThreadRestartParams(thread: "3f9a2c17be04", force: true)))
        #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        let bare = Data(#"{"caller":{"client":"x"},"id":"1","method":"thread.restart","params":{"thread":"3f9a2c17be04"},"rpc":1}"#.utf8)
        #expect(try ControlRequest.decode(bare).get().call == .threadRestart(ThreadRestartParams(thread: "3f9a2c17be04")))
        #expect(ControlMethod.threadRestart.isMutating)
    }
}
