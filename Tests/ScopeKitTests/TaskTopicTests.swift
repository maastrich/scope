import Foundation
import Testing
import ScopeCore
@testable import ScopeControl
@testable import ScopeTasks

/// Topics: the label tasks of one piece of work share, so the sidebar files them together.
@Suite struct TaskTopicTests {
    @Test func aTopicIsTrimmedCollapsedAndBounded() {
        #expect(TaskTopic.normalize("  auth   rework \n") == "auth rework")
        #expect(TaskTopic.normalize("   ") == nil)
        #expect(TaskTopic.normalize(nil) == nil)
        #expect(TaskTopic.normalize(String(repeating: "a", count: 200))?.count == TaskTopic.maxLength)
    }

    @Test func spellingsThatDifferInCaseAreOneTopic() {
        #expect(TaskTopic.key("Auth Rework") == TaskTopic.key("auth  rework"))
        #expect(TaskTopic.distinct(["Auth rework", "auth rework", nil, "billing"]) == ["Auth rework", "billing"])
    }

    /// The point of the thing: what an agent splits off lands next to it without the agent thinking about it.
    @Test func aTaskCreatedFromATaskInheritsItsTopic() {
        let inherited = TaskTopic.inherit(requested: nil, parentTopic: "auth rework", parentName: "Split the login")
        #expect(inherited.child == "auth rework")
        #expect(inherited.parent == nil)
    }

    @Test func aParentWithoutATopicLendsItsName() {
        let lent = TaskTopic.inherit(requested: nil, parentTopic: nil, parentName: "Split the login")
        #expect(lent.child == "Split the login")
        #expect(lent.parent == "Split the login")
    }

    @Test func theTopicAskedForWinsAndLeavesTheParentAlone() {
        let named = TaskTopic.inherit(requested: " billing ", parentTopic: "auth rework", parentName: "x")
        #expect(named.child == "billing")
        #expect(named.parent == nil)
        let fromParentless = TaskTopic.inherit(requested: "billing", parentTopic: nil, parentName: "x")
        #expect(fromParentless.parent == nil)
    }

    /// An orchestrator at the scope root has no task to inherit from.
    @Test func outsideATaskThereIsNothingToInherit() {
        let none = TaskTopic.inherit(requested: nil, parentTopic: nil, parentName: nil)
        #expect(none.child == nil && none.parent == nil)
    }

    @Test func theSidebarGathersATopicWhereItsFirstTaskStands() {
        let entries = TaskTopic.entries([
            (id: 1, topic: nil), (id: 2, topic: "Auth"), (id: 3, topic: nil), (id: 4, topic: "auth"), (id: 5, topic: "Billing"),
        ])
        #expect(entries == [.task(1), .topic("Auth", [2, 4]), .task(3), .topic("Billing", [5])])
        #expect(TaskTopic.entries([(id: 1, topic: String?.none)]) == [.task(1)])
    }
}

@Suite struct TaskRecordTopicTests {
    static let base = #"{"version":1,"id":"3f9a2c17be04","scopeID":"acme","slug":"s","branch":"b","root":"/tmp/s""#

    @Test func aRecordFromBeforeTopicsHasNone() throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data((Self.base + "}").utf8))
        #expect(record.topic == nil && record.parentTask == nil && record.origin == nil)
        #expect(!record.createdByAgent)
    }

    @Test func aBrokenParentDoesNotLoseTheTask() throws {
        let json = Self.base + #","topic":"  auth ","parentTask":"not-an-id","origin":{"author":"control","parent":"aaaaaaaaaaaa","depth":1}}"#
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        #expect(record.topic == "auth")
        #expect(record.parentTask == nil)
        #expect(record.createdByAgent)
    }

    @Test func whatTheBudgetCountsAsAnAgentsTask() {
        func record(createdBy: String?, origin: ThreadOrigin?) -> TaskRecord {
            TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/tmp", scopeSlug: "acme", name: "n", slug: "s",
                       branch: "b", root: "/tmp/s", createdBy: createdBy, origin: origin)
        }
        #expect(!record(createdBy: nil, origin: nil).createdByAgent)
        #expect(!record(createdBy: "scope-cli/1", origin: ThreadOrigin(author: .control, client: "scope-cli/1")).createdByAgent)
        #expect(record(createdBy: "scope-cli/1", origin: .child(of: "aaaaaaaaaaaa", origin: nil, depth: 1, client: "scope-cli/1")).createdByAgent)
        // Before origins were kept, only `scope mcp` says for certain that an agent asked.
        #expect(record(createdBy: "scope-mcp/1", origin: nil).createdByAgent)
    }
}

@Suite struct TaskTopicFacadeTests {
    @Test func theCommandLineTakesATopic() throws {
        guard case .call(.taskNew(let params), _) = try ScopeCLI.parse(["task", "new", "split it", "--topic", "auth rework"]) else {
            Issue.record("that is a task")
            return
        }
        #expect(params.topic == "auth rework")
    }

    @Test func theMCPToolTakesATopic() throws {
        let call = try MCPBridge.call(tool: "scope_task_new", arguments: Data(#"{"prompt":"x","topic":"auth"}"#.utf8)).get()
        #expect(call == .taskNew(TaskNewParams(prompt: "x", topic: "auth")))
    }

    @Test func anOlderClientSendsNoTopic() throws {
        let params = try JSONDecoder().decode(TaskNewParams.self, from: Data(#"{"prompt":"x"}"#.utf8))
        #expect(params.topic == nil)
    }

    @Test func theListShowsTheTopic() {
        let text = CLIRenderer.text(.list(ListResult(tasks: [
            TaskSummary(id: "3f9a2c17be04", name: "Split", slug: "split", branch: "b", scope: "Acme", scopeSlug: "acme",
                        root: "/tmp/split", repos: [], threads: [], topic: "auth rework"),
        ])))
        #expect(text.contains("TOPIC"))
        #expect(text.contains("auth rework"))
    }
}
