import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `task.restore`: an agent picks an archived task back up, through the same Restore the archive notice offers.
@Suite struct TaskRestoreTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static let restore = ControlCall.taskRestore(TaskRestoreParams(task: "rework-auth"))

    static func parse(_ words: [String]) throws -> ControlCall? {
        guard case .call(let call, _) = try ScopeCLI.parse(words) else { return nil }
        return call
    }

    @Test func theCommandLineTakesOneTaskAndAScope() throws {
        #expect(try Self.parse(["task", "restore", "rework-auth"]) == Self.restore)
        #expect(try Self.parse(["task", "restore", "rework-auth", "--scope", "acme"])
            == .taskRestore(TaskRestoreParams(task: "rework-auth", scope: "acme")))
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "restore"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "restore", "a", "b"]) }
    }

    @Test func theMCPToolMapsOntoTheSameCall() {
        func call(_ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: "scope_task_restore", arguments: Data(json.utf8))
        }
        #expect(call(#"{"task":"rework-auth"}"#) == .success(Self.restore))
        #expect(call(#"{"slug":"rework-auth","scope":"acme"}"#)
            == .success(.taskRestore(TaskRestoreParams(task: "rework-auth", scope: "acme"))))
        guard case .failure(let error) = call("{}") else {
            Issue.record("a restore without a task should be refused")
            return
        }
        #expect(error.code == .badRequest)
        let tool = MCPBridge.tools.first { $0.name == "scope_task_restore" }
        #expect(tool?.readOnly == false)
        #expect(tool?.description.contains("uncommitted changes") == true)
    }

    @Test func theRequestAndItsAnswerRoundTrip() throws {
        let request = ControlRequest(id: "abcd1234", caller: ControlCaller(client: "scope-cli/1"),
                                     call: .taskRestore(TaskRestoreParams(task: "rework-auth", scope: "acme")))
        #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        let response = ControlResponse.result(id: "abcd1234", .action(ActionResult(message: "restored", task: "t1"), .taskRestore))
        #expect(try ControlResponse.decode(try response.encoded(), method: .taskRestore) == response)
        #expect(ControlMethod.taskRestore.isMutating)
        #expect(Self.restore.timeout == ControlCall.taskArchive(TaskArchiveParams(task: "t")).timeout)
    }

    // MARK: Policy

    @Test func itCostsATaskLikeANewOne() {
        #expect(AutomationPolicy.cost(of: Self.restore) == AutomationLoad(tasks: 1))
    }

    @Test func theBudgetStopsAnAgentButNeverYou() {
        let policy = AutomationPolicy(settings: AutomationSettings(maxAgentTasks: 3))
        #expect(policy.decide(Self.restore, from: .thread(Self.thread, depth: 1), load: AutomationLoad(tasks: 2)) == .allow)
        guard case .refuse(let error) = policy.decide(Self.restore, from: .thread(Self.thread, depth: 1),
                                                      load: AutomationLoad(tasks: 3)) else {
            Issue.record("a restore past the task budget must be refused")
            return
        }
        #expect(error.code == .denied)
        #expect(policy.decide(Self.restore, from: .user, load: AutomationLoad(tasks: 50)) == .allow)
    }

    @Test func itFollowsTheApprovalOfCreatingTasks() {
        let asking = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask(let subject) = asking.decide(Self.restore, from: .externalAgent(client: "scope-mcp/1")) else {
            Issue.record("tasks set to ask must ask before a restore")
            return
        }
        #expect(subject.contains("rework-auth"))
        let denied = AutomationPolicy(settings: AutomationSettings(tasks: .deny))
        guard case .refuse = denied.decide(Self.restore, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("tasks turned off for agents must refuse a restore")
            return
        }
        let off = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false))
        #expect(off.decide(Self.restore, from: .thread(Self.thread, depth: 0)) != .allow)
    }

    /// The task keeps its place in the chain: bringing it back opens no new generation.
    @Test func theDepthLimitDoesNotApply() {
        let fenced = AutomationPolicy(settings: AutomationSettings(depthLimit: 1))
        #expect(fenced.decide(Self.restore, from: .thread(Self.thread, depth: 4)) == .allow)
    }

    // MARK: Finding archived tasks

    @Test func theListMarksArchivedTasks() throws {
        let archived = TaskSummary(id: "t1", name: "Rework auth", slug: "rework-auth", branch: "feat/auth", scope: "Acme",
                                   scopeSlug: "acme", root: "/r", repos: [], threads: [],
                                   archivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let live = TaskSummary(id: "t2", name: "Split", slug: "split", branch: "feat/split", scope: "Acme",
                               scopeSlug: "acme", root: "/s", repos: ["api"], threads: [])
        let text = CLIRenderer.text(.list(ListResult(tasks: [archived, live])))
        #expect(text.contains("rework-auth (archived)"))
        #expect(!text.contains("split (archived)"))
        // A live task's JSON is what it was before the field existed.
        let json = String(decoding: try ControlProtocol.makeEncoder().encode(live), as: UTF8.self)
        #expect(!json.contains("archivedAt"))
        let response = ControlResponse.result(id: "1", .list(ListResult(tasks: [archived, live])))
        #expect(try ControlResponse.decode(try response.encoded(), method: .list) == response)
    }
}
