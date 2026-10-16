import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `scope release`: the one call that ships something, in both façades, with its own approval that asks by default.
@Suite struct ReleaseCommandTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static let release = ControlCall.release(ReleaseParams(version: "1.2.3"))

    static func parse(_ words: [String]) throws -> ControlCall? {
        guard case .call(let call, _) = try ScopeCLI.parse(words) else { return nil }
        return call
    }

    @Test func theCommandLineTakesAVersionAndItsFlags() throws {
        #expect(try Self.parse(["release"]) == .release(ReleaseParams()))
        #expect(try Self.parse(["release", "1.2.3"]) == Self.release)
        #expect(try Self.parse(["release", "v1.2.3"]) == Self.release)
        #expect(try Self.parse(["release", "1.2.3-rc.1", "--dry-run", "--force", "--repo", "api", "--scope", "acme"])
            == .release(ReleaseParams(version: "1.2.3-rc.1", repo: "api", scope: "acme", dryRun: true, force: true)))
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["release", "1.2"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["release", "1.2.3", "1.2.4"]) }
        #expect(ScopeCLI.usage.contains("scope release"))
    }

    @Test func theMCPToolMapsOntoTheSameCall() {
        func call(_ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: "scope_release", arguments: Data(json.utf8))
        }
        #expect(call("{}") == .success(.release(ReleaseParams())))
        #expect(call(#"{"version":"1.2.3","dry_run":true,"repo":"api"}"#)
            == .success(.release(ReleaseParams(version: "1.2.3", repo: "api", dryRun: true))))
        // The spellings an agent guesses.
        #expect(call(#"{"tag":"1.2.3","repository":"api","preview":true}"#)
            == .success(.release(ReleaseParams(version: "1.2.3", repo: "api", dryRun: true))))
        let tool = MCPBridge.tools.first { $0.name == "scope_release" }
        #expect(tool?.destructive == true)
        #expect(tool?.readOnly == false)
        #expect(tool?.description.contains("release.sh") == true)
    }

    @Test func theRequestAndItsAnswerRoundTrip() throws {
        for params in [ReleaseParams(), ReleaseParams(version: "1.2.3", repo: "api", scope: "acme", dryRun: true, force: true)] {
            let request = ControlRequest(id: "abcd1234", caller: ControlCaller(client: "scope-cli/1"), call: .release(params))
            #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        }
        let result = ReleaseResult(repo: "api", scopeSlug: "acme", branch: "main", head: "0123456789abcdef", tag: "v1.2.3",
                                   released: true, dryRun: false, method: "scripts/release.sh", checkout: "/h/releases/acme-api",
                                   ci: "green (2 runs)", output: "==> v1.2.3 pushed.\n", truncated: false)
        let response = ControlResponse.result(id: "abcd1234", .release(result))
        #expect(try ControlResponse.decode(try response.encoded(), method: .release) == response)
        #expect(ControlMethod.release.isMutating && ControlMethod.release.isGated)
        // A clone, the checks and the script: well past an archive's five minutes, on both sides of the socket.
        #expect(Self.release.timeout > ControlCall.taskArchive(TaskArchiveParams(task: "t")).timeout)
        #expect(Self.release.serverDeadline(floor: .seconds(180)) > .seconds(600))
    }

    // MARK: Policy

    @Test func itAsksByDefaultAndADryRunDoesNot() {
        #expect(AutomationPolicy.cost(of: Self.release) == .zero)
        let defaults = AutomationPolicy(settings: AutomationSettings())
        #expect(AutomationSettings().releases == .ask)
        guard case .ask(let subject) = defaults.decide(Self.release, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("a release asks by default")
            return
        }
        #expect(subject.contains("v1.2.3"))
        guard case .ask(let next) = defaults.decide(.release(ReleaseParams(repo: "api", force: true)), from: .externalAgent(client: "scope-mcp/1")) else {
            Issue.record("an agent outside Scope is asked too")
            return
        }
        #expect(next.contains("api") && next.contains("the next version") && next.contains("CI unchecked"))
        #expect(defaults.decide(.release(ReleaseParams(dryRun: true)), from: .thread(Self.thread, depth: 2)) == .allow)
        #expect(defaults.decide(Self.release, from: .user) == .allow)
        #expect(AutomationPolicy(settings: AutomationSettings(releases: .allow)).decide(Self.release, from: .thread(Self.thread, depth: 0)) == .allow)
        guard case .refuse(let error) = AutomationPolicy(settings: AutomationSettings(releases: .deny)).decide(Self.release, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("releases turned off for agents must refuse")
            return
        }
        #expect(error.code == .denied)
        // The task approval has no say: a release is not a task.
        #expect(AutomationPolicy(settings: AutomationSettings(tasks: .deny, releases: .allow)).decide(Self.release, from: .thread(Self.thread, depth: 0)) == .allow)
    }

    @Test func theSettingSurvivesOlderConfigsAndBadWords() throws {
        func decode(_ json: String) throws -> AutomationSettings {
            try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}").releases == .ask)
        #expect(try decode(#"{"releases":"allow"}"#).releases == .allow)
        #expect(try decode(#"{"releases":"whenever"}"#).releases == .ask)
        let encoded = String(decoding: try JSONEncoder().encode(AutomationSettings(releases: .deny)), as: UTF8.self)
        #expect(encoded.contains(#""releases":"deny""#))
        #expect(try decode(encoded).releases == .deny)
    }

    // MARK: Rendering and the skill

    @Test func theAnswerSaysWhatHappenedThenQuotesTheScript() {
        let shipped = ReleaseResult(repo: "api", scopeSlug: "acme", branch: "main", head: "0123456789abcdef0123", tag: "v1.2.3",
                                    released: true, dryRun: false, method: "scripts/release.sh", checkout: "/h/releases/acme-api",
                                    ci: "green (2 runs)", output: "==> v1.2.3 pushed.\n")
        let text = CLIRenderer.text(.release(shipped))
        #expect(text.hasPrefix("released v1.2.3 of api in acme"))
        #expect(text.contains("main @ 0123456789ab") && text.contains("green (2 runs)") && text.contains("==> v1.2.3 pushed."))
        let preview = ReleaseResult(repo: ".", scopeSlug: "scope", branch: "main", head: "abc", tag: nil, released: false, dryRun: true,
                                    method: "scripts/release.sh", checkout: "/h", output: "notes", truncated: true)
        let dry = CLIRenderer.text(.release(preview))
        #expect(dry.hasPrefix("dry run of a release for . in scope: nothing was pushed"))
        #expect(dry.contains("output cut"))
        let ping = CLIRenderer.text(.ping(PingResult(app: "Scope", version: "1", home: "/h", automation: AutomationSettings())))
        #expect(ping.contains("releases ask"))
    }

    @Test func theSkillTellsAgentsAboutIt() {
        let text = SkillInstaller(userHome: FileManager.default.temporaryDirectory, debug: false).skillText
        #expect(text.contains("scope release"))
        #expect(text.contains("scope_release"))
        #expect(text.contains("Releases"))
        #expect(text.contains("release.sh"))
    }
}
