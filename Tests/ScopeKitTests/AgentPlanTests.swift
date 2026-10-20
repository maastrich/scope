import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

/// `AgentPlan`: the fold of the todo and plan tools a thread reports, and its place in `ThreadActivity`.
@Suite struct AgentPlanTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!

    static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    /// A `PostToolUse` as Claude Code sends it on stdin, forwarded whole in `raw` by `scope-hook turn.started --stdin`.
    static func postToolUse(_ tool: String, input: [String: Any], _ seconds: TimeInterval) -> AdapterEvent {
        let object: [String: Any] = ["session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": tool,
                                     "tool_input": input, "tool_response": ["ok": true]]
        let raw = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return AdapterEvent(threadID: thread, kind: .turnStarted, payload: [HookEvent.toolKey: tool], raw: raw, receivedAt: at(seconds))
    }

    static func todos(_ items: [(String, String, String?)]) -> [String: Any] {
        ["todos": items.map { item -> [String: Any] in
            var object: [String: Any] = ["content": item.0, "status": item.1]
            if let active = item.2 { object["activeForm"] = active }
            return object
        }]
    }

    static var threeTodos: [String: Any] { todos([("Read the spec", "completed", "Reading the spec"),
                                   ("Write the card", "in_progress", "Writing the card"),
                                   ("Run the tests", "pending", "Running the tests")]) }

    // MARK: TodoWrite

    @Test func aTodoWriteBecomesTheStepsWithTheirStatuses() throws {
        let plan = try #require(AgentPlan.applying(input: Self.threeTodos, to: nil, at: Self.at(1)))
        #expect(plan.steps.map(\.text) == ["Read the spec", "Write the card", "Run the tests"])
        #expect(plan.steps.map(\.status) == [.completed, .inProgress, .pending])
        #expect(plan.done == 1)
        #expect(plan.total == 3)
        #expect(plan.summary == "1/3 steps")
        #expect(plan.isInProgress)
        #expect(plan.source == .todos)
        #expect(plan.updatedAt == Self.at(1))
        #expect(plan.title == nil)
    }

    @Test func theCurrentStepIsTheOneInProgressElseTheFirstPending() throws {
        let plan = try #require(AgentPlan.applying(input: Self.threeTodos, to: nil, at: Self.at(1)))
        #expect(plan.currentStep?.text == "Write the card")
        // Shown in its active form while it runs.
        #expect(plan.currentStep?.label == "Writing the card")
        #expect(plan.headline == "1/3 steps · Writing the card")

        let none = try #require(AgentPlan.applying(input: Self.todos([("A", "completed", nil), ("B", "pending", nil)]), to: nil, at: Self.at(1)))
        #expect(none.currentStep?.text == "B")
        #expect(none.currentStep?.label == "B")

        let done = try #require(AgentPlan.applying(input: Self.todos([("A", "completed", nil)]), to: nil, at: Self.at(1)))
        #expect(done.currentStep == nil)
        #expect(!done.isInProgress)
        #expect(done.headline == "1/1 steps")
    }

    @Test func aLaterTodoWriteReplacesTheList() throws {
        let first = try #require(AgentPlan.applying(input: Self.threeTodos, to: nil, at: Self.at(1)))
        let next = try #require(AgentPlan.applying(input: Self.todos([("Ship it", "pending", nil)]), to: first, at: Self.at(2)))
        #expect(next.steps.map(\.text) == ["Ship it"])
        #expect(next.updatedAt == Self.at(2))
    }

    @Test func anEmptyTodoListClearsTheSteps() throws {
        let first = try #require(AgentPlan.applying(input: Self.threeTodos, to: nil, at: Self.at(1)))
        let cleared = try #require(AgentPlan.applying(input: ["todos": [] as [Any]], to: first, at: Self.at(2)))
        #expect(cleared.steps.isEmpty)
        #expect(cleared.summary == "no steps")
        #expect(!cleared.isInProgress)
    }

    @Test func statusWordsOfOtherDriversFoldOntoTheThreeStates() {
        #expect(AgentPlan.Status(loose: "todo") == .pending)
        #expect(AgentPlan.Status(loose: "In-Progress") == .inProgress)
        #expect(AgentPlan.Status(loose: "done") == .completed)
        #expect(AgentPlan.Status(loose: "cancelled") == nil)
    }

    // MARK: Generic shapes

    @Test func aRenamedToolWithTheSameShapeIsReadAsSteps() throws {
        let input: [String: Any] = ["items": [["text": "One", "status": "done"], ["title": "Two", "status": "todo"]]]
        let plan = try #require(AgentPlan.applying(input: input, to: nil, at: Self.at(1)))
        #expect(plan.steps.map(\.text) == ["One", "Two"])
        #expect(plan.steps.map(\.status) == [.completed, .pending])
        #expect(AgentPlan.isCandidate(tool: "TaskList"))
        #expect(AgentPlan.isCandidate(tool: "update_plan"))
        #expect(!AgentPlan.isCandidate(tool: "Bash"))
    }

    @Test func unknownShapesChangeNothingAndFailNothing() {
        #expect(AgentPlan.applying(input: ["command": "ls"], to: nil, at: Self.at(1)) == nil)
        // An array whose elements have no status is not a list of steps, and an empty array under another key says nothing.
        #expect(AgentPlan.applying(input: ["todos": [["content": "x"]]], to: nil, at: Self.at(1)) == nil)
        #expect(AgentPlan.applying(input: ["files": [] as [Any]], to: nil, at: Self.at(1)) == nil)
        // An item with a status this build does not know is not a step either: the whole array is left alone.
        #expect(AgentPlan.applying(input: ["todos": [["content": "x", "status": "cancelled"]]], to: nil, at: Self.at(1)) == nil)
        #expect(AgentPlan.applying(tool: "TodoWrite", raw: "{not json", to: nil, at: Self.at(1)) == nil)
        #expect(AgentPlan.applying(tool: "TodoWrite", raw: nil, to: nil, at: Self.at(1)) == nil)
    }

    // MARK: Plan mode

    static let planMarkdown = """
    # Plan card for the inspector

    Some context about **why**.

    1. Add `AgentPlan` to ScopeKit
    2. Draw the card
       - with its rows
    3) Document it

    - a plain bullet, not a step
    """

    @Test func aPlanOutOfPlanModeSetsTheTitleAndItsNumberedItemsBecomeTheSteps() throws {
        let plan = try #require(AgentPlan.applying(input: ["plan": Self.planMarkdown], to: nil, at: Self.at(1)))
        #expect(plan.title == "Plan card for the inspector")
        #expect(plan.steps.map(\.text) == ["Add AgentPlan to ScopeKit", "Draw the card", "Document it"])
        #expect(plan.steps.allSatisfy { $0.status == .pending })
        #expect(plan.source == .plan)
        #expect(plan.summary == "0/3 steps")
    }

    @Test func checkboxesCarryTheirState() {
        let parsed = AgentPlan.parsePlan(markdown: "Fix the login\n\n- [x] Find the bug\n- [ ] Write a test\n* [X] Ship")
        #expect(parsed.title == "Fix the login")
        #expect(parsed.steps.map(\.status) == [.completed, .pending, .completed])
    }

    @Test func aPlanWithoutAHeadingIsTitledByItsFirstLine() {
        let parsed = AgentPlan.parsePlan(markdown: "\n\nRefactor the parser, then the tests.\n\nNo list here.")
        #expect(parsed.title == "Refactor the parser, then the tests.")
        #expect(parsed.steps.isEmpty)
    }

    @Test func aPlanKeepsTheTodoListTheAgentAlreadyHas() throws {
        let todos = try #require(AgentPlan.applying(input: Self.threeTodos, to: nil, at: Self.at(1)))
        let plan = try #require(AgentPlan.applying(input: ["plan": Self.planMarkdown], to: todos, at: Self.at(2)))
        #expect(plan.title == "Plan card for the inspector")
        #expect(plan.steps == todos.steps)
        #expect(plan.source == .todos)
    }

    @Test func aPlanFillsAnEmptyListAndTheNextPlanReplacesIt() throws {
        let first = try #require(AgentPlan.applying(input: ["plan": Self.planMarkdown], to: nil, at: Self.at(1)))
        let second = try #require(AgentPlan.applying(input: ["plan": "# Smaller plan\n\n1. Only this"], to: first, at: Self.at(2)))
        #expect(second.title == "Smaller plan")
        #expect(second.steps.map(\.text) == ["Only this"])
        // A plan with no list leaves the steps of the previous plan, and takes the title.
        let third = try #require(AgentPlan.applying(input: ["plan": "# Prose only\n\nJust words."], to: second, at: Self.at(3)))
        #expect(third.title == "Prose only")
        #expect(third.steps.map(\.text) == ["Only this"])
        // A todo list after a plan replaces the plan's steps and keeps its title.
        let todos = try #require(AgentPlan.applying(input: Self.threeTodos, to: third, at: Self.at(4)))
        #expect(todos.title == "Prose only")
        #expect(todos.steps.count == 3)
        #expect(todos.source == .todos)
    }

    // MARK: In the activity

    @Test func aPostToolUseOfTodoWriteLandsInTheActivity() {
        let activity = [
            AdapterEvent(threadID: Self.thread, kind: .turnStarted, receivedAt: Self.at(0)),
            Self.postToolUse("TodoWrite", input: Self.threeTodos, 1),
        ].reduce(ThreadActivity()) { $0.apply($1) }
        #expect(activity.plan?.summary == "1/3 steps")
        #expect(activity.plan?.currentStep?.label == "Writing the card")
        #expect(activity.plan?.updatedAt == Self.at(1))
        // The call still counts as a tool call of the turn.
        #expect(activity.turnTools == 1)
        #expect(activity.lastTool?.name == "TodoWrite")
    }

    @Test func aToolThatIsNotAboutAPlanLeavesItAlone() {
        let activity = [
            Self.postToolUse("TodoWrite", input: Self.threeTodos, 1),
            Self.postToolUse("Bash", input: ["command": "swift test"], 2),
            Self.postToolUse("ExitPlanMode", input: ["plan": "# Titled\n\nwords"], 3),
        ].reduce(ThreadActivity()) { $0.apply($1) }
        #expect(activity.plan?.steps.count == 3)
        #expect(activity.plan?.title == "Titled")
        #expect(activity.plan?.updatedAt == Self.at(3))
    }

    /// A `TodoWrite` reported after `Stop` (a background agent finishing its list) is still the latest plan, even
    /// though it opens no turn.
    @Test func aLateTodoWriteStillUpdatesThePlan() {
        let activity = [
            AdapterEvent(threadID: Self.thread, kind: .turnStarted, receivedAt: Self.at(0)),
            AdapterEvent(threadID: Self.thread, kind: .turnEnded, receivedAt: Self.at(1)),
            Self.postToolUse("TodoWrite", input: Self.todos([("Done", "completed", nil)]), 2),
        ].reduce(ThreadActivity()) { $0.apply($1) }
        #expect(!activity.inTurn)
        #expect(activity.plan?.summary == "1/1 steps")
    }

    @Test func thePlanSurvivesTheFileAndARestart() throws {
        let activity = [Self.postToolUse("TodoWrite", input: Self.threeTodos, 1)].reduce(ThreadActivity()) { $0.apply($1) }
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(activity)
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadActivity.self, from: data)
        #expect(decoded.plan == activity.plan)
        // Read back under what arrived since: the saved plan stands until a new one comes.
        #expect(ThreadActivity().restoring(decoded).plan == activity.plan)
        let newer = [Self.postToolUse("TodoWrite", input: Self.todos([("New", "pending", nil)]), 5)].reduce(ThreadActivity()) { $0.apply($1) }
        #expect(newer.restoring(decoded).plan?.steps.map(\.text) == ["New"])
    }

    @Test func anActivityFileWithoutAPlanStillDecodes() throws {
        let json = #"{"version":1,"turnTools":0,"turns":[]}"#
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadActivity.self, from: Data(json.utf8))
        #expect(decoded.plan == nil)
    }

    // MARK: Task tools

    /// A `PostToolUse` with its `tool_response`, as Claude Code sends it for the task tools.
    static func taskCall(_ tool: String, input: [String: Any], response: [String: Any], _ seconds: TimeInterval) -> AdapterEvent {
        let object: [String: Any] = ["session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": tool,
                                     "tool_input": input, "tool_response": response]
        let raw = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return AdapterEvent(threadID: thread, kind: .turnStarted, payload: [HookEvent.toolKey: tool], raw: raw, receivedAt: at(seconds))
    }

    static func create(_ id: String, _ subject: String, _ seconds: TimeInterval, active: String? = nil) -> AdapterEvent {
        var input: [String: Any] = ["subject": subject, "description": "Details of \(subject)"]
        if let active { input["activeForm"] = active }
        return taskCall("TaskCreate", input: input, response: ["task": ["id": id, "subject": subject]], seconds)
    }

    static func update(_ id: String, _ status: String, _ seconds: TimeInterval) -> AdapterEvent {
        taskCall("TaskUpdate", input: ["taskId": id, "status": status],
                 response: ["success": true, "taskId": id, "updatedFields": ["status"]], seconds)
    }

    /// A task hook (`TaskCreated`, `TaskCompleted`), forwarded as `driver.reported` with its stdin in `raw`.
    static func taskHook(_ name: String, id: String, subject: String, _ seconds: TimeInterval) -> AdapterEvent {
        let object: [String: Any] = ["session_id": "s1", "hook_event_name": name, "task_id": id,
                                     "task_subject": subject, "task_description": "Details"]
        let raw = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return AdapterEvent(threadID: thread, kind: .driverReported, raw: raw, receivedAt: at(seconds))
    }

    static func fold(_ events: [AdapterEvent]) -> ThreadActivity {
        events.reduce(ThreadActivity()) { $0.apply($1) }
    }

    @Test func taskCreateAddsStepsAndTaskUpdateMovesThemById() throws {
        let activity = Self.fold([
            Self.create("1", "Pick the license", 1, active: "Picking the license"),
            Self.create("2", "Write LICENSE", 2),
            Self.create("3", "Commit", 3),
            Self.update("1", "in_progress", 4),
        ])
        let plan = try #require(activity.plan)
        #expect(plan.source == .tasks)
        #expect(plan.steps.map(\.id) == ["1", "2", "3"])
        #expect(plan.steps.map(\.status) == [.inProgress, .pending, .pending])
        #expect(plan.currentStep?.label == "Picking the license")
        #expect(plan.summary == "0/3 steps")

        let later = Self.fold([Self.create("1", "Pick the license", 1), Self.create("2", "Write LICENSE", 2),
                               Self.update("1", "completed", 3), Self.update("2", "deleted", 4)])
        #expect(later.plan?.steps.map(\.text) == ["Pick the license"])
        #expect(later.plan?.summary == "1/1 steps")
    }

    @Test func taskUpdateRenamesAndAnUnknownIdWithoutTextChangesNothing() throws {
        let created = try #require(Self.fold([Self.create("1", "Old", 1)]).plan)
        let renamed = AgentPlan.applying(input: ["taskId": "1", "subject": "New", "activeForm": "Doing new"],
                                         response: ["success": true, "taskId": "1"], to: created, at: Self.at(2))
        #expect(renamed?.steps.first?.text == "New")
        #expect(renamed?.steps.first?.activeForm == "Doing new")
        #expect(AgentPlan.applying(input: ["taskId": "9", "status": "completed"], response: ["success": true],
                                   to: created, at: Self.at(3)) == nil)
        #expect(AgentPlan.applying(input: ["taskId": "9", "status": "deleted"], response: [:], to: created, at: Self.at(3)) == nil)
    }

    @Test func taskListReplacesTheListAndKeepsWhatItDoesNotSay() throws {
        let activity = Self.fold([
            Self.create("1", "A", 1, active: "Doing A"),
            Self.taskCall("TaskList", input: [:], response: ["tasks": [
                ["id": "1", "subject": "A", "status": "in_progress", "blockedBy": [] as [String]],
                ["id": "2", "subject": "B", "status": "pending", "blockedBy": ["1"]],
            ]], 2),
        ])
        let plan = try #require(activity.plan)
        #expect(plan.steps.map(\.text) == ["A", "B"])
        #expect(plan.steps.map(\.status) == [.inProgress, .pending])
        // `TaskList` gives no active form; the one `TaskCreate` gave stays.
        #expect(plan.steps.first?.activeForm == "Doing A")
    }

    @Test func taskHooksAddAndCompleteStepsOutsideAToolCall() throws {
        let activity = Self.fold([
            Self.taskHook("TaskCreated", id: "1", subject: "Investigate", 1),
            Self.taskHook("TaskCreated", id: "2", subject: "Fix", 2),
            Self.taskHook("TaskCompleted", id: "1", subject: "Investigate", 3),
        ])
        let plan = try #require(activity.plan)
        #expect(plan.steps.map(\.text) == ["Investigate", "Fix"])
        #expect(plan.steps.map(\.status) == [.completed, .pending])
        // Informational: no turn opened, no tool counted.
        #expect(!activity.inTurn)
        #expect(activity.turnTools == 0)
        // The same task reported by its tool call and by its hook is one step.
        let both = Self.fold([Self.create("1", "Investigate", 1), Self.taskHook("TaskCreated", id: "1", subject: "Investigate", 2)])
        #expect(both.plan?.steps.count == 1)
    }

    @Test func tasksReplaceAPlansStepsButKeepItsTitle() throws {
        let activity = Self.fold([
            Self.postToolUse("ExitPlanMode", input: ["plan": Self.planMarkdown], 1),
            Self.create("1", "Only task", 2),
        ])
        let plan = try #require(activity.plan)
        #expect(plan.title == "Plan card for the inspector")
        #expect(plan.steps.map(\.text) == ["Only task"])
        // A todo list still replaces everything, tasks included.
        let todos = Self.fold([Self.create("1", "Task", 1), Self.postToolUse("TodoWrite", input: Self.threeTodos, 2)])
        #expect(todos.plan?.source == .todos)
        #expect(todos.plan?.steps.count == 3)
    }

    @Test func aStringToolResponseIsParsedToo() throws {
        let object: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                                     "tool_input": ["subject": "S", "description": "D"],
                                     "tool_response": #"{"task":{"id":"7","subject":"S"}}"#]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let plan = try #require(AgentPlan.applying(tool: "TaskCreate", raw: raw, to: nil, at: Self.at(1)))
        #expect(plan.steps.map(\.id) == ["7"])
    }

    /// Tools named like plan tools but about other things — background jobs, sub-agents, Scope's own MCP task calls —
    /// leave the plan alone even when their response holds a `task` with an id, or their input a `taskId`.
    @Test func toolsAboutOtherKindsOfTasksLeaveThePlanAlone() {
        let task: [String: Any] = ["task": ["id": "x", "name": "y", "title": "z"]]
        let activity = Self.fold([
            Self.taskCall("TaskStop", input: ["task_id": "b1"], response: task, 1),
            Self.taskCall("TaskOutput", input: ["task_id": "b1"], response: task, 2),
            Self.taskCall("mcp__scope__scope_task_new", input: ["prompt": "p"], response: task, 3),
            Self.taskCall("mcp__scope__scope_task_show", input: ["taskId": "x", "status": "done"], response: task, 4),
            Self.taskCall("update_task_status", input: ["taskId": "x", "status": "done", "title": "T"], response: task, 5),
        ])
        #expect(activity.plan == nil)
        #expect(!AgentPlan.isCandidate(tool: "TaskStop"))
        #expect(!AgentPlan.isCandidate(tool: "mcp__scope__scope_task_new"))
    }
}
