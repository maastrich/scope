import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// A mission's milestones: named by the orchestrator, marked done, validated by Scope, and what the record and the
/// context file say of them.
@Suite struct MissionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let child = TaskID(rawValue: "aaaaaaaaaaa1")!

    private var record: TaskRecord {
        TaskRecord(
            scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/s/acme", scopeSlug: "acme", scopeName: "Acme",
            name: "Rework auth", slug: "rework-auth", branch: "feat/rework-auth", root: "/h/sandboxes/acme/rework-auth",
            repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/h/sandboxes/acme/rework-auth/api", branch: "feat/rework-auth")],
            prompt: "Replace the session cookies with refresh tokens.", topic: "auth", mission: Mission()
        )
    }

    @Test func milestonesAreAddedInOrderAndFoundByNumberIdOrTitle() throws {
        var mission = Mission()
        let first = try mission.add(title: "  Token model ", validation: "pnpm test").get()
        let second = try mission.add(title: "Refresh endpoint", validation: " ").get()
        #expect(mission.milestones.map(\.title) == ["Token model", "Refresh endpoint"])
        #expect(first.validation == "pnpm test" && second.validation == nil)
        #expect(mission.index(of: "2") == 1)
        #expect(mission.index(of: first.id) == 0)
        #expect(mission.index(of: "refresh ENDPOINT") == 1)
        #expect(mission.index(of: "3") == nil && mission.index(of: "0") == nil && mission.index(of: "nope") == nil)
        #expect(mission.add(title: "   ") == .failure(.emptyTitle))
        #expect(mission.caption == "0/2 milestones" && Mission().caption == "no milestones yet")
    }

    @Test func doneWithoutAValidationIsReachedAndWithOneWaitsForIt() throws {
        var mission = Mission()
        _ = mission.add(title: "Plan")
        _ = mission.add(title: "Tests", validation: "swift test --filter AuthTests")
        let plan = try mission.markDone(0, at: t0).get()
        #expect(plan.state == .done && plan.state.isComplete && plan.doneAt == t0)
        #expect(mission.progress == (1, 2) && mission.next?.title == "Tests")

        let tests = try mission.markDone(1, task: child, at: t0).get()
        #expect(tests.state == .done && tests.task == child)
        mission.applyValidation(1, succeeded: false, exit: "exit 1", output: "3 tests failed", at: t0)
        #expect(mission.milestones[1].state == .failed && mission.milestones[1].log == "3 tests failed")
        #expect(mission.progress == (1, 2) && mission.next?.title == "Tests")

        // Marked done again after the fix: the old verdict goes; validated, the mission is reached.
        _ = try mission.markDone(1, at: t0).get()
        #expect(mission.milestones[1].log == nil && mission.milestones[1].exit == nil)
        mission.applyValidation(1, succeeded: true, exit: "exit 0", output: "", at: t0)
        #expect(mission.milestones[1].state == .validated && mission.progress == (2, 2) && mission.next == nil)
        #expect(mission.markDone(1, at: t0) == .failure(.alreadyReached("Tests")))
        #expect(mission.markDone(7, at: t0) == .failure(.noSuchMilestone))
    }

    @Test func theLogIsBoundedAndTheFailureMessageCarriesIt() {
        let long = (0..<2000).map { "line \($0)" }.joined(separator: "\n")
        let tail = Mission.tail(long)!
        #expect(tail.utf8.count <= Mission.logLimit + 2 && tail.hasPrefix("…\nline ") && tail.hasSuffix("line 1999"))
        #expect(Mission.tail("  \n ") == nil && Mission.tail("ok") == "ok")
        var milestone = Milestone(title: "Tests", validation: "pnpm test")
        milestone.exit = "exit 1"
        milestone.log = "FAIL auth.test.ts"
        let message = Mission.failureMessage(milestone: milestone, command: "pnpm test")
        #expect(message.hasPrefix("[Scope: the validation of milestone “Tests” failed (exit 1).]"))
        #expect(message.contains("Command: `pnpm test`") && message.contains("```\nFAIL auth.test.ts\n```"))
    }

    @Test func theRecordKeepsItsMissionAndAnOldRecordHasNone() throws {
        var record = record
        _ = record.mission?.add(title: "Token model", validation: "pnpm test", task: child)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: data)
        #expect(decoded.isMission && decoded.mission?.milestones.first?.task == child)
        #expect(decoded.mission?.milestones.first?.validation == "pnpm test")
        var plain = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        plain.removeValue(forKey: "mission")
        let old = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: plain))
        #expect(!old.isMission)
        // A milestone with an unknown state is open, not a refused record.
        let odd = #"{"milestones":[{"title":"x","state":"paused"}]}"#
        #expect(try JSONDecoder().decode(Mission.self, from: Data(odd.utf8)).milestones.first?.state == .open)
    }

    @Test func theContextFileExplainsTheProtocolAndListsTheMilestones() {
        var record = record
        _ = record.mission?.add(title: "Token model", validation: "pnpm test")
        _ = record.mission?.markDone(0, at: t0)
        record.mission?.applyValidation(0, succeeded: true, exit: "exit 0", output: "", at: t0)
        _ = record.mission?.add(title: "Refresh endpoint")
        let md = TaskProjection.agentsMarkdown(task: record, otherRepos: [], scopeName: "Acme")
        #expect(md.contains("## Mission\n\nThis task is a **mission**"))
        #expect(md.contains("`scope task milestone add rework-auth \"<title>\" --validate \"<command>\"`"))
        #expect(md.contains("--topic \"auth\""))
        #expect(md.contains("Open the next milestone only once the previous one is validated."))
        #expect(md.contains("Milestones so far (1/2 milestones):\n1. [validated] Token model — validate: `pnpm test`\n2. [open] Refresh endpoint"))
        let plain = TaskProjection.agentsMarkdown(task: TaskRecord(scopeID: record.scopeID, scopeRoot: "/s", scopeSlug: "a",
                                                                   name: "n", slug: "n", branch: "b", root: "/r"),
                                                  otherRepos: [], scopeName: "Acme")
        #expect(!plain.contains("## Mission"))
    }
}
