import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `task.checkpoints` and `task.restore-checkpoint`: the two façades, the wire, the policy and what the terminal prints.
@Suite struct TaskCheckpointControlTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static let list = ControlCall.taskCheckpoints(TaskCheckpointsParams(task: "rework-auth"))
    static let restore = ControlCall.taskRestoreCheckpoint(TaskRestoreCheckpointParams(task: "rework-auth", number: 3))

    static func parse(_ words: [String]) throws -> ControlCall? {
        guard case .call(let call, _) = try ScopeCLI.parse(words) else { return nil }
        return call
    }

    @Test func theCommandLineTakesAnOptionalTaskAndANumber() throws {
        #expect(try Self.parse(["task", "checkpoints", "rework-auth"]) == Self.list)
        #expect(try Self.parse(["task", "checkpoints"]) == .taskCheckpoints(TaskCheckpointsParams()))
        #expect(try Self.parse(["task", "checkpoints", "rework-auth", "--scope", "acme"])
            == .taskCheckpoints(TaskCheckpointsParams(task: "rework-auth", scope: "acme")))
        #expect(try Self.parse(["task", "restore-checkpoint", "rework-auth", "3"]) == Self.restore)
        #expect(try Self.parse(["task", "restore-checkpoint", "3"]) == .taskRestoreCheckpoint(TaskRestoreCheckpointParams(number: 3)))
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "restore-checkpoint"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "restore-checkpoint", "rework-auth", "three"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "restore-checkpoint", "rework-auth", "0"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try Self.parse(["task", "checkpoints", "a", "b"]) }
        #expect(ScopeCLI.usage.contains("scope task checkpoints") && ScopeCLI.usage.contains("scope task restore-checkpoint"))
    }

    @Test func theMCPToolsMapOntoTheSameCalls() {
        func call(_ tool: String, _ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: tool, arguments: Data(json.utf8))
        }
        #expect(call("scope_task_checkpoints", #"{"task":"rework-auth"}"#) == .success(Self.list))
        #expect(call("scope_task_checkpoints", "{}") == .success(.taskCheckpoints(TaskCheckpointsParams())))
        #expect(call("scope_task_restore_checkpoint", #"{"slug":"rework-auth","number":3}"#) == .success(Self.restore))
        #expect(call("scope_task_restore_checkpoint", #"{"task":"rework-auth","n":3}"#) == .success(Self.restore))
        guard case .failure = call("scope_task_restore_checkpoint", #"{"task":"rework-auth"}"#) else {
            Issue.record("a restore without a number must be refused")
            return
        }
        let list = MCPBridge.tools.first { $0.name == "scope_task_checkpoints" }
        let restore = MCPBridge.tools.first { $0.name == "scope_task_restore_checkpoint" }
        #expect(list?.readOnly == true && restore?.readOnly == false && restore?.destructive == true)
        #expect(restore?.description.contains("checkpointed first") == true)
    }

    @Test func theRequestsAndTheirAnswersRoundTrip() throws {
        for call in [Self.list, Self.restore, .taskCheckpoints(TaskCheckpointsParams()),
                     .taskRestoreCheckpoint(TaskRestoreCheckpointParams(number: 1, scope: "acme"))] {
            let request = ControlRequest(id: "abcd1234", caller: ControlCaller(client: "scope-cli/1"), call: call)
            #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        }
        let entry = TaskCheckpointsResult.Entry(number: 3, at: Date(timeIntervalSince1970: 1_760_000_000), reason: "turn",
                                                thread: Self.thread.rawValue, threadTitle: "Claude Code", turn: 4,
                                                said: "Added the tests", additions: 12, deletions: 3, repos: ["api"])
        let result = TaskCheckpointsResult(task: "t1", slug: "rework-auth", checkpoints: [entry])
        let response = ControlResponse.result(id: "abcd1234", .taskCheckpoints(result))
        #expect(try ControlResponse.decode(try response.encoded(), method: .taskCheckpoints) == response)
        let action = ControlResponse.result(id: "abcd1234", .action(ActionResult(message: "restored", task: "t1"), .taskRestoreCheckpoint))
        #expect(try ControlResponse.decode(try action.encoded(), method: .taskRestoreCheckpoint) == action)
        #expect(!ControlMethod.taskCheckpoints.isMutating && !ControlMethod.taskCheckpoints.isGated)
        #expect(ControlMethod.taskRestoreCheckpoint.isMutating && ControlMethod.taskRestoreCheckpoint.isGated)
    }

    // MARK: Policy

    @Test func listingIsFreeAndRestoringIsForTheTasksOwnThread() {
        let policy = AutomationPolicy(settings: AutomationSettings(tasks: .deny))
        #expect(policy.decide(Self.list, from: .thread(Self.thread, depth: 1)) == .allow)
        // Which task is the question, and the app answers it once it has found the task.
        #expect(policy.decide(Self.restore, from: .thread(Self.thread, depth: 1)) == .allow)
        #expect(AutomationPolicy.cost(of: Self.restore) == .zero)

        let own = Self.thread
        let other = ThreadID(rawValue: "aaaaaaaaaaaa")!
        #expect(AutomationPolicy.mayRestoreCheckpoint(of: "rework-auth", taskThreads: [own], from: .user) == nil)
        #expect(AutomationPolicy.mayRestoreCheckpoint(of: "rework-auth", taskThreads: [own, other], from: .thread(own, depth: 0)) == nil)
        #expect(AutomationPolicy.mayRestoreCheckpoint(of: "rework-auth", taskThreads: [other], from: .thread(own, depth: 0))?.code == .denied)
        #expect(AutomationPolicy.mayRestoreCheckpoint(of: "rework-auth", taskThreads: [], from: .externalAgent(client: "scope-mcp/1"))?.code == .denied)
        #expect(AutomationPolicy.subject(of: Self.restore).contains("checkpoint 3"))
    }

    // MARK: Rendering

    @Test func theTerminalListsOneLinePerCheckpoint() {
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        let turn = TaskCheckpointsResult.Entry(number: 1, at: at, reason: "turn", thread: Self.thread.rawValue, threadTitle: "Claude Code",
                                               turn: 2, said: "Added the tests", additions: 12, deletions: 3, repos: ["api"])
        let undo = TaskCheckpointsResult.Entry(number: 2, at: at, reason: "before_restore", additions: 0, deletions: 4, repos: ["api"])
        let text = CLIRenderer.text(.taskCheckpoints(TaskCheckpointsResult(task: "t1", slug: "rework-auth", checkpoints: [turn, undo])))
        #expect(text.contains("Claude Code") && text.contains("+12 -3") && text.contains("Added the tests"))
        #expect(text.contains("before restore") && text.contains("scope task restore-checkpoint rework-auth <N>"))
        let empty = CLIRenderer.text(.taskCheckpoints(TaskCheckpointsResult(task: "t1", slug: "rework-auth", checkpoints: [])))
        #expect(empty.contains("no checkpoint yet"))
        #expect((try? CLIRenderer.json(.taskCheckpoints(TaskCheckpointsResult(task: "t1", slug: "s", checkpoints: [turn]))))?.contains("\"said\"") == true)
    }

    @Test func theSkillTellsAgentsAboutIt() {
        let text = SkillInstaller(userHome: FileManager.default.temporaryDirectory, debug: false).skillText
        #expect(text.contains("scope task checkpoints") && text.contains("scope_task_checkpoints"))
        #expect(text.contains("scope task restore-checkpoint") && text.contains("scope_task_restore_checkpoint"))
        #expect(text.contains("refs/scope/checkpoints"))
    }
}
