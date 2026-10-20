import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `scope task branch add|list|remove` and `scope thread new --branch` through every façade: the CLI spelling, the
/// MCP tools, the wire, the policy and what the terminal prints.
@Suite struct TaskBranchControlTests {
    static let caller = ControlCaller(thread: "3f9a2c17be04", task: nil, cwd: "/tmp/work", client: "scope-cli/test")

    @Test func theCommandLineSpellsTheThreeVerbs() throws {
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "add", "fix/login"])
            == .taskBranchAdd(TaskBranchAddParams(branch: "fix/login")))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "add", "auth", "fix/login", "--repo", "api", "--from", "feat/base", "--scope", "acme"])
            == .taskBranchAdd(TaskBranchAddParams(task: "auth", branch: "fix/login", repo: "api", from: "feat/base", scope: "acme")))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "add", "pr-42", "--pr", "#42"])
            == .taskBranchAdd(TaskBranchAddParams(branch: "pr-42", pr: "#42")))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "list"]) == .taskBranchList(TaskBranchListParams()))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "list", "auth"]) == .taskBranchList(TaskBranchListParams(task: "auth")))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "remove", "auth", "fix/login", "--repo", "api"])
            == .taskBranchRemove(TaskBranchRemoveParams(task: "auth", branch: "fix/login", repo: "api")))
        #expect(try ScopeCLIParsingTests.call(["task", "branch", "rm", "fix/login"]) == .taskBranchRemove(TaskBranchRemoveParams(branch: "fix/login")))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "branch", "add"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "branch", "add", "x", "--from", "a", "--pr", "1"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "branch", "list", "a", "b"]) }
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "branch", "prune"]) }
    }

    @Test func aThreadOpensOnABranchOfItsTask() throws {
        #expect(try ScopeCLIParsingTests.call(["thread", "new", "--task", "auth", "--branch", "fix/login", "-p", "go"])
            == .threadNew(ThreadNewParams(task: "auth", prompt: "go", branch: "fix/login")))
        // The branch is one of the task's worktrees: without a task it names nothing.
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["thread", "new", "--branch", "fix/login"]) }
    }

    @Test func theToolsMapOntoTheSameCalls() throws {
        func call(_ tool: String, _ json: String) -> Result<ControlCall, ControlError> {
            MCPBridge.call(tool: tool, arguments: Data(json.utf8))
        }
        #expect(call("scope_task_branch_add", #"{"branch":"fix/login"}"#) == .success(.taskBranchAdd(TaskBranchAddParams(branch: "fix/login"))))
        #expect(call("scope_task_branch_add", #"{"task":"auth","branch":"fix/login","repo":"api","from":"feat/base"}"#)
            == .success(.taskBranchAdd(TaskBranchAddParams(task: "auth", branch: "fix/login", repo: "api", from: "feat/base"))))
        // The spellings an agent guesses from the task tool and the CLI.
        #expect(call("scope_task_branch_add", "{\"slug\":\"auth\",\"name\":\"fix/login\",\"start_pr\":\"#42\"}")
            == .success(.taskBranchAdd(TaskBranchAddParams(task: "auth", branch: "fix/login", pr: "#42"))))
        #expect(call("scope_task_branch_list", "{}") == .success(.taskBranchList(TaskBranchListParams())))
        #expect(call("scope_task_branch_remove", #"{"branch":"fix/login","repository":"api"}"#)
            == .success(.taskBranchRemove(TaskBranchRemoveParams(branch: "fix/login", repo: "api"))))
        #expect(call("scope_thread_new", #"{"task":"auth","branch":"fix/login"}"#)
            == .success(.threadNew(ThreadNewParams(task: "auth", branch: "fix/login"))))
        let byName = Dictionary(uniqueKeysWithValues: MCPBridge.tools.map { ($0.name, $0) })
        #expect(byName["scope_task_branch_add"]?.destructive == true)
        #expect(byName["scope_task_branch_list"]?.readOnly == true)
        #expect(byName["scope_task_branch_remove"]?.destructive == true)
    }

    @Test func theCallsAndTheListRoundTrip() throws {
        for call in [ControlCall.taskBranchAdd(TaskBranchAddParams(task: "auth", branch: "fix/login", repo: "api", pr: "#42")),
                     .taskBranchList(TaskBranchListParams()), .taskBranchRemove(TaskBranchRemoveParams(branch: "fix/login")),
                     .threadNew(ThreadNewParams(task: "auth", branch: "fix/login"))] {
            let request = ControlRequest(id: "abcd1234", caller: Self.caller, call: call)
            #expect(try ControlRequest.decode(try request.encoded()).get() == request)
        }
        // A list without parameters is the caller's own task.
        let body = Data(#"{"caller":{"client":"x"},"id":"7","method":"task.branch.list","rpc":1}"#.utf8)
        #expect(try ControlRequest.decode(body).get().call == .taskBranchList(TaskBranchListParams()))
        let result = TaskBranchListResult(task: "0123456789ab", slug: "auth", worktrees: [
            .init(repo: "api", branch: "feat/auth", worktree: "/s/auth/api", primary: true,
                  pullRequests: [PullRequestSummary(number: 12, url: URL(string: "https://github.com/acme/api/pull/12")!, state: "open")]),
            .init(repo: "api", branch: "fix/login", worktree: "/s/auth/api@login", primary: false, base: "origin/main"),
        ])
        let answer = ControlResponse.result(id: "7", .taskBranches(result))
        #expect(try ControlResponse.decode(try answer.encoded(), method: .taskBranchList) == answer)
        let text = CLIRenderer.text(.taskBranches(result))
        #expect(text.contains("feat/auth") && text.contains("task branch") && text.contains("#12 open"))
        #expect(text.contains("fix/login") && text.contains("from origin/main") && text.contains("api@login"))
        #expect(text.contains("scope task branch add auth"))
        #expect(!(try CLIRenderer.json(.taskBranches(result))).isEmpty)
        #expect(ControlMethod.taskBranchList.isMutating == false && ControlMethod.taskBranchAdd.isMutating && ControlMethod.taskBranchRemove.isMutating)
    }

    @Test func addingAndRemovingFollowTheTaskApprovalAndListingIsFree() {
        let thread = ControlOrigin.thread(ThreadID(rawValue: "3f9a2c17be04")!, depth: 0)
        let add = ControlCall.taskBranchAdd(TaskBranchAddParams(branch: "fix/login"))
        let remove = ControlCall.taskBranchRemove(TaskBranchRemoveParams(task: "auth", branch: "fix/login"))
        let list = ControlCall.taskBranchList(TaskBranchListParams())
        let open = AutomationPolicy(settings: AutomationSettings())
        #expect(open.decide(add, from: thread) == .allow)
        #expect(open.decide(remove, from: thread) == .allow)
        // No budget: a worktree opens no agent.
        #expect(AutomationPolicy.cost(of: add) == .zero)
        let asking = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask(let subject) = asking.decide(add, from: thread) else {
            Issue.record("tasks set to ask must ask before a worktree is written")
            return
        }
        #expect(subject.contains("fix/login") && subject.contains("its own task"))
        guard case .ask(let removal) = asking.decide(remove, from: thread) else {
            Issue.record("tasks set to ask must ask before a worktree is removed")
            return
        }
        #expect(removal.contains("auth"))
        #expect(asking.decide(list, from: thread) == .allow)
        let denied = AutomationPolicy(settings: AutomationSettings(tasks: .deny))
        guard case .refuse = denied.decide(add, from: thread) else {
            Issue.record("tasks turned off for agents refuses a worktree too")
            return
        }
        #expect(denied.decide(list, from: thread) == .allow)
        #expect(AutomationPolicy(settings: AutomationSettings(tasks: .deny)).decide(add, from: .user) == .allow)
    }
}
