import Foundation
import Synchronization
import Testing
import ScopeCore
import ScopeDrivers
@testable import ScopeAssist

/// The second tier: a tool-free argv or nothing, the prompt it sends, the object it reads back.
@Suite struct HeadlessAssistModelTests {
    final class Recorder: HeadlessRunner, Sendable {
        private let recorded = Mutex<[String]>([])
        let output: String
        init(output: String) { self.output = output }
        var argv: [String] { recorded.withLock { $0 } }
        func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
            recorded.withLock { $0 = argv }
            return ProcessResult(exitCode: 0, terminationReason: .exit, stdout: Data(output.utf8), stderr: Data())
        }
    }

    let home = URL(fileURLWithPath: "/tmp/scope-assist-tests", isDirectory: true)
    let assistArgv = ["claude", "-p", "{prompt}", "--output-format", "json", "--model", "haiku", "--tools", "",
                      "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"]

    func profile(_ argv: [String]?) -> DriverProfile {
        DriverProfile(id: "claude-code", name: "Claude Code", command: "claude",
                      headlessLight: ["claude", "-p", "{prompt}", "--tools", "Bash", "--allowedTools", "Bash(gh pr view:*)"],
                      headlessAssist: argv)
    }

    @Test func theBundledArgvIsToolFreeAndTheLightOneIsNot() {
        #expect(HeadlessAssistModel.isToolFree(assistArgv))
        #expect(!HeadlessAssistModel.isToolFree(profile(nil).headlessLight!))
        #expect(!HeadlessAssistModel.isToolFree([]))
        #expect(!HeadlessAssistModel.isToolFree(["claude", "-p", "{prompt}"]))
        #expect(!HeadlessAssistModel.isToolFree(["claude", "-p", "{prompt}", "--tools", "", "--dangerously-skip-permissions"]))
        #expect(!HeadlessAssistModel.isToolFree(["claude", "-p", "{prompt}", "--tools", "", "--allowedTools", "Bash"]))
        #expect(HeadlessAssistModel.isToolFree(["claude", "-p", "{prompt}", "--tools="]))
    }

    @Test func theBundledClaudeProfilesDeclareAToolFreeAssistArgv() throws {
        let claude = try DriverRegistry.bundledProfiles().filter { $0.id.hasPrefix("claude-code") }
        #expect(claude.count == 2)
        for profile in claude {
            let argv = try #require(profile.headlessAssist)
            #expect(HeadlessAssistModel.isToolFree(argv))
            #expect(argv.firstIndex(of: "{prompt}")! < argv.firstIndex(of: "--tools")!)
        }
    }

    @Test func aProfileWithoutAssistArgvIsUnavailable() async {
        let model = HeadlessAssistModel(profile: profile(nil), runner: Recorder(output: ""), home: home, cwd: home)
        #expect(await !model.isAvailable)
        await #expect(throws: AssistError.argvAllowsTools) {
            let _: ThreadDigest = try await model.classify(instructions: "x", input: "y", schema: ThreadDigest.schema)
        }
    }

    @Test func theLightArgvIsRefusedEvenWhenHandedAsAssist() async {
        let model = HeadlessAssistModel(profile: profile(profile(nil).headlessLight), runner: Recorder(output: ""), home: home, cwd: home)
        await #expect(throws: AssistError.argvAllowsTools) {
            let _: ThreadDigest = try await model.classify(instructions: "x", input: "y", schema: ThreadDigest.schema)
        }
    }

    @Test func thePromptGoesBeforeTheVariadicFlagsAndTheAnswerIsDecoded() async throws {
        let runner = Recorder(output: #"{"type":"result","is_error":false,"result":"```json\n{\"activity\":\"Retrying swift test\",\"stuck\":true,\"reason\":\"same error\"}\n```"}"#)
        let model = HeadlessAssistModel(profile: profile(assistArgv), runner: runner, home: home, cwd: home)
        #expect(await model.isAvailable)
        let digest: ThreadDigest = try await model.classify(instructions: ThreadDigest.instructions, input: "tail", schema: ThreadDigest.schema)
        #expect(digest == ThreadDigest(activity: "Retrying swift test", stuck: true, reason: "same error"))
        let argv = runner.argv
        #expect(argv[0] == "claude" && argv[1] == "-p")
        #expect(argv[2].contains("tail") && argv[2].contains("\"stuck\": \"boolean"))
        #expect(argv.suffix(from: 3) == assistArgv.suffix(from: 3))
    }

    @Test func aDriverErrorAndAnAnswerThatIsNotTheObjectBothThrow() async {
        let failing = HeadlessAssistModel(profile: profile(assistArgv),
                                          runner: Recorder(output: #"{"is_error":true,"result":"rate limit"}"#), home: home, cwd: home)
        await #expect(throws: HeadlessError.driverReportedError("rate limit")) {
            let _: ThreadDigest = try await failing.classify(instructions: "x", input: "y", schema: ThreadDigest.schema)
        }
        let prose = HeadlessAssistModel(profile: profile(assistArgv), runner: Recorder(output: #"{"result":"I cannot tell."}"#), home: home, cwd: home)
        await #expect(throws: AssistError.self) {
            let _: ThreadDigest = try await prose.classify(instructions: "x", input: "y", schema: ThreadDigest.schema)
        }
    }
}
