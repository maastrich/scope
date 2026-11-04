import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `scope task remove` and `scope task sweep` through every façade: the CLI spelling, the MCP tools, the wire and the
/// automation policy — GitHub never touched by an agent without the user saying so.
@Suite struct TaskSweepControlTests {
    static let caller = ControlCaller(thread: "3f9a2c17be04", task: nil, cwd: "/tmp/work", client: "scope-cli/test")
    static let thread = ControlOrigin.thread(ThreadID(rawValue: "3f9a2c17be04")!, depth: 0)

    @Test func theCommandLineNamesWhatToRemove() throws {
        #expect(try ScopeCLIParsingTests.call(["task", "remove", "repo", "web"])
            == .taskRemove(TaskRemoveParams(element: .repo, target: "web")))
        #expect(try ScopeCLIParsingTests.call(["task", "remove", "auth", "pr", "#42"])
            == .taskRemove(TaskRemoveParams(task: "auth", element: .pullRequest, target: "#42")))
        #expect(try ScopeCLIParsingTests.call(["task", "rm", "branch", "fix/login", "--repo", "api"])
            == .taskRemove(TaskRemoveParams(element: .worktree, target: "fix/login", repo: "api")))
        #expect(try ScopeCLIParsingTests.call(["task", "remove", "issue"]) == .taskRemove(TaskRemoveParams(element: .issue)))
        #expect(try ScopeCLIParsingTests.call(["task", "remove", "auth", "topic"]) == .taskRemove(TaskRemoveParams(task: "auth", element: .topic)))
        #expect(try ScopeCLIParsingTests.call(["task", "remove", "--task", "topic", "milestone", "2"])
            == .taskRemove(TaskRemoveParams(task: "topic", element: .milestone, target: "2")))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "remove"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "remove", "repo"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "remove", "issue", "12"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "remove", "auth", "everything"]) }
    }

    @Test func aSweepFromTheCommandLineOnlyListsUntilYes() throws {
        // Without --yes the command says what would go and does nothing.
        #expect(try ScopeCLIParsingTests.call(["task", "sweep"]) == .taskSweep(TaskSweepParams(dryRun: true)))
        #expect(try ScopeCLIParsingTests.call(["task", "sweep", "auth", "--yes"]) == .taskSweep(TaskSweepParams(task: "auth")))
        #expect(try ScopeCLIParsingTests.call(["task", "sweep", "auth", "--yes", "--keep-branches", "--close-prs", "--delete-remote-branches"])
            == .taskSweep(TaskSweepParams(task: "auth", resetBranches: false, closePullRequests: true, deleteRemoteBranches: true)))
        #expect(try ScopeCLIParsingTests.call(["task", "sweep", "auth", "--undo"]) == .taskSweep(TaskSweepParams(task: "auth", undo: true)))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "sweep", "a", "b"]) }
    }

    @Test func theToolsMapOntoTheSameCalls() {
        func call(_ tool: String, _ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: tool, arguments: Data(json.utf8))
        }
        #expect(call("scope_task_remove", #"{"element":"repo","target":"web"}"#)
            == .success(.taskRemove(TaskRemoveParams(element: .repo, target: "web"))))
        #expect(call("scope_task_remove", ##"{"task":"auth","element":"pr","target":"#42"}"##)
            == .success(.taskRemove(TaskRemoveParams(task: "auth", element: .pullRequest, target: "#42"))))
        #expect(call("scope_task_remove", #"{"element":"issue"}"#) == .success(.taskRemove(TaskRemoveParams(element: .issue))))
        if case .success = call("scope_task_remove", #"{"element":"repo"}"#) { Issue.record("a repository needs naming") }
        if case .success = call("scope_task_remove", #"{"element":"everything"}"#) { Issue.record("an unknown element is refused") }
        // An agent sweeping gets the sweep, not a preview: autonomy first.
        #expect(call("scope_task_sweep", "{}") == .success(.taskSweep(TaskSweepParams())))
        #expect(call("scope_task_sweep", #"{"dry_run":true,"reset_branches":false}"#)
            == .success(.taskSweep(TaskSweepParams(resetBranches: false, dryRun: true))))
        #expect(call("scope_task_sweep", #"{"task":"auth","close_pull_requests":true,"delete_remote_branches":true}"#)
            == .success(.taskSweep(TaskSweepParams(task: "auth", closePullRequests: true, deleteRemoteBranches: true))))
        #expect(call("scope_task_sweep", #"{"undo":true}"#) == .success(.taskSweep(TaskSweepParams(undo: true))))
        let byName = Dictionary(uniqueKeysWithValues: MCPBridge.tools.map { ($0.name, $0) })
        #expect(byName["scope_task_remove"]?.destructive == true)
        #expect(byName["scope_task_sweep"]?.destructive == true)
        #expect(byName["scope_task_remove"]?.description.contains("NOT closed on GitHub") == true)
    }

    @Test func theCallsRoundTrip() throws {
        for call in [ControlCall.taskRemove(TaskRemoveParams(task: "auth", element: .pullRequest, target: "#42", repo: "api")),
                     .taskRemove(TaskRemoveParams(element: .topic)),
                     .taskSweep(TaskSweepParams(task: "auth", resetBranches: false, closePullRequests: true, dryRun: true)),
                     .taskSweep(TaskSweepParams(undo: true))] {
            let request = ControlRequest(id: "abcd1234", caller: Self.caller, call: call)
            #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        }
        // A sweep without parameters is the caller's own task, branches reset, nothing on GitHub.
        let body = Data(#"{"caller":{"client":"x"},"id":"7","method":"task.sweep","rpc":1}"#.utf8)
        #expect(try ControlRequest.decode(body).get().call == .taskSweep(TaskSweepParams()))
        let answer = ControlResponse.result(id: "7", .action(ActionResult(message: "swept auth"), .taskSweep))
        #expect(try ControlResponse.decode(try answer.encoded(), method: .taskSweep) == answer)
        #expect(ControlMethod.taskSweep.isMutating && ControlMethod.taskRemove.isMutating)
    }

    @Test func aSweepFollowsTheTaskApprovalButGitHubAlwaysAsksTheUser() {
        let sweep = ControlCall.taskSweep(TaskSweepParams(task: "auth"))
        let closing = ControlCall.taskSweep(TaskSweepParams(task: "auth", closePullRequests: true))
        let deleting = ControlCall.taskSweep(TaskSweepParams(deleteRemoteBranches: true))
        let preview = ControlCall.taskSweep(TaskSweepParams(closePullRequests: true, dryRun: true))
        let open = AutomationPolicy(settings: AutomationSettings())
        #expect(open.decide(sweep, from: Self.thread) == .allow)
        #expect(open.decide(preview, from: Self.thread) == .allow)
        // GitHub: the user approves it every time, even with tasks allowed.
        guard case .ask(let subject) = open.decide(closing, from: Self.thread) else {
            Issue.record("closing pull requests on GitHub must wait for the user")
            return
        }
        #expect(subject.contains("closing its pull requests on GitHub") && subject.contains("auth"))
        guard case .ask(let remote) = open.decide(deleting, from: .externalAgent(client: "scope-mcp/1")) else {
            Issue.record("deleting remote branches must wait for the user")
            return
        }
        #expect(remote.contains("deleting its branches on origin"))
        let asking = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask = asking.decide(sweep, from: Self.thread) else {
            Issue.record("tasks set to ask must ask before a sweep")
            return
        }
        let denied = AutomationPolicy(settings: AutomationSettings(tasks: .deny))
        guard case .refuse = denied.decide(sweep, from: Self.thread), case .refuse = denied.decide(closing, from: Self.thread) else {
            Issue.record("tasks turned off for agents refuses a sweep")
            return
        }
        #expect(denied.decide(preview, from: Self.thread) == .allow)
        // You decide for yourself.
        #expect(denied.decide(closing, from: .user) == .allow)
        #expect(AutomationPolicy.cost(of: sweep) == .zero)
    }

    @Test func removingALabelIsFreeRemovingAWorktreeIsTheTaskApproval() {
        let asking = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        #expect(asking.decide(.taskRemove(TaskRemoveParams(element: .topic)), from: Self.thread) == .allow)
        #expect(asking.decide(.taskRemove(TaskRemoveParams(element: .milestone, target: "2")), from: Self.thread) == .allow)
        for element in [TaskRemoveElement.repo, .worktree, .pullRequest, .issue] {
            guard case .ask(let subject) = asking.decide(.taskRemove(TaskRemoveParams(task: "auth", element: element, target: "x")), from: Self.thread) else {
                Issue.record("removing \(element) waits for the task approval")
                continue
            }
            #expect(subject.contains("auth"))
        }
    }
}
