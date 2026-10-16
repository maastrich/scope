import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `task.rebase`: an agent or the user brings a task up to date with main on demand, and `scope list tasks` shows the lag.
@Suite struct TaskRebaseTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static let rebase = ControlCall.taskRebase(TaskRebaseParams(task: "rework-auth"))

    static func parse(_ words: [String]) throws -> ControlCall? {
        guard case .call(let call, _) = try ScopeCLI.parse(words) else { return nil }
        return call
    }

    @Test func theCommandLineTakesAnOptionalTaskAndAScope() throws {
        #expect(try Self.parse(["task", "rebase", "rework-auth"]) == Self.rebase)
        #expect(try Self.parse(["task", "rebase"]) == .taskRebase(TaskRebaseParams()))
        #expect(try Self.parse(["task", "rebase", "rework-auth", "--scope", "acme"])
            == .taskRebase(TaskRebaseParams(task: "rework-auth", scope: "acme")))
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "rebase", "a", "b"]) }
        #expect(ScopeCLI.usage.contains("scope task rebase"))
    }

    @Test func theMCPToolMapsOntoTheSameCall() {
        func call(_ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: "scope_task_rebase", arguments: Data(json.utf8))
        }
        #expect(call(#"{"task":"rework-auth"}"#) == .success(Self.rebase))
        #expect(call(#"{"slug":"rework-auth","scope":"acme"}"#)
            == .success(.taskRebase(TaskRebaseParams(task: "rework-auth", scope: "acme"))))
        #expect(call("{}") == .success(.taskRebase(TaskRebaseParams())))
        let tool = MCPBridge.tools.first { $0.name == "scope_task_rebase" }
        #expect(tool?.readOnly == false)
        #expect(tool?.description.contains("force-with-lease") == true)
    }

    @Test func theRequestAndItsAnswerRoundTrip() throws {
        for params in [TaskRebaseParams(), TaskRebaseParams(task: "rework-auth", scope: "acme")] {
            let request = ControlRequest(id: "abcd1234", caller: ControlCaller(client: "scope-cli/1"), call: .taskRebase(params))
            #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        }
        let response = ControlResponse.result(id: "abcd1234", .action(ActionResult(message: "rebased", task: "t1"), .taskRebase))
        #expect(try ControlResponse.decode(try response.encoded(), method: .taskRebase) == response)
        #expect(ControlMethod.taskRebase.isMutating && ControlMethod.taskRebase.isGated)
        #expect(Self.rebase.timeout == ControlCall.taskArchive(TaskArchiveParams(task: "t")).timeout)
    }

    // MARK: Policy

    @Test func itCostsNothingAndFollowsTheApprovalOfTasks() {
        #expect(AutomationPolicy.cost(of: Self.rebase) == .zero)
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(Self.rebase, from: .thread(Self.thread, depth: 1)) == .allow)
        let asking = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask(let subject) = asking.decide(Self.rebase, from: .externalAgent(client: "scope-mcp/1")) else {
            Issue.record("tasks set to ask must ask before a rebase")
            return
        }
        #expect(subject.contains("rework-auth") && subject.contains("main"))
        let denied = AutomationPolicy(settings: AutomationSettings(tasks: .deny))
        guard case .refuse = denied.decide(Self.rebase, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("tasks turned off for agents must refuse a rebase")
            return
        }
        #expect(denied.decide(Self.rebase, from: .user) == .allow)
    }

    // MARK: Listing

    @Test func theListShowsBehindConflictsAndTheHold() throws {
        let behind = TaskSummary(id: "t1", name: "Rework auth", slug: "rework-auth", branch: "feat/auth", scope: "Acme",
                                 scopeSlug: "acme", root: "/r", repos: ["api"], threads: [], behind: 4, conflicts: 2)
        let fresh = TaskSummary(id: "t2", name: "Split", slug: "split", branch: "feat/split", scope: "Acme",
                                scopeSlug: "acme", root: "/s", repos: ["api"], threads: [], behind: 0, conflicts: 0, holdBranch: true)
        let unknown = TaskSummary(id: "t3", name: "New", slug: "new", branch: "feat/new", scope: "Acme",
                                  scopeSlug: "acme", root: "/n", repos: ["api"], threads: [])
        #expect(CLIRenderer.mainColumn(behind) == "behind 4, 2 conflicts")
        #expect(CLIRenderer.mainColumn(fresh) == "up to date, held")
        #expect(CLIRenderer.mainColumn(unknown) == "")
        let text = CLIRenderer.text(.list(ListResult(tasks: [behind, fresh, unknown])))
        #expect(text.contains("MAIN") && text.contains("behind 4, 2 conflicts"))
        // A task never measured carries none of the fields.
        let json = String(decoding: try ControlProtocol.makeEncoder().encode(unknown), as: UTF8.self)
        #expect(!json.contains("behind") && !json.contains("holdBranch"))
        let response = ControlResponse.result(id: "1", .list(ListResult(tasks: [behind, fresh, unknown])))
        #expect(try ControlResponse.decode(try response.encoded(), method: .list) == response)
    }

    @Test func theSkillTellsAgentsAboutIt() {
        let text = SkillInstaller(userHome: FileManager.default.temporaryDirectory, debug: false).skillText
        #expect(text.contains("scope task rebase"))
        #expect(text.contains("scope_task_rebase"))
        #expect(text.contains("When main moves"))
    }
}
