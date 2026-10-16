import Foundation
import Testing
import ScopeCore
@testable import ScopeControl
@testable import ScopeTasks

/// Best-of-N: one brief run N ways, named and planned so the kept one can take the plain name back.
@Suite struct TaskAttemptsTests {
    @Test func attemptsAreNamedAfterTheBriefAndNumbered() {
        #expect(TaskAttempts.name(base: "Refresh tokens", index: 2) == "Refresh tokens · attempt 2")
        #expect(TaskAttempts.branch(base: "feat/refresh-tokens", index: 3) == "feat/refresh-tokens-a3")
        #expect(TaskAttempts.slug(base: "refresh-tokens", index: 1) == "refresh-tokens-a1")
        #expect(TaskAttempts.topic(for: "  Refresh   tokens ") == "Refresh tokens")
    }

    @Test func thePlainBranchDropsTheSuffixOnly() {
        #expect(TaskAttempts.plainBranch("feat/x-a2") == "feat/x")
        #expect(TaskAttempts.plainBranch("feat/x-a12") == "feat/x")
        #expect(TaskAttempts.plainBranch("feat/x") == "feat/x")
        #expect(TaskAttempts.plainBranch("feat/alpha-a") == "feat/alpha-a")
        #expect(TaskAttempts.plainBranch("feat/x-a0") == "feat/x-a0")
    }

    @Test func modelsAndDriversSpreadOneForAllOrOneEach() throws {
        let plan = try TaskAttempts.plan(count: 3, name: "Fix it", slug: "fix-it", branch: "fix/it",
                                         models: ["opus"], drivers: ["claude-code", "codex", "cursor"]).get()
        #expect(plan.map(\.index) == [1, 2, 3])
        #expect(plan.map(\.model) == ["opus", "opus", "opus"])
        #expect(plan.map(\.driver) == ["claude-code", "codex", "cursor"])
        #expect(plan.map(\.branch) == ["fix/it-a1", "fix/it-a2", "fix/it-a3"])
        #expect(plan.map(\.name) == ["Fix it · attempt 1", "Fix it · attempt 2", "Fix it · attempt 3"])
        let none = try TaskAttempts.plan(count: 2, name: "n", slug: "n", branch: "n", models: [], drivers: []).get()
        #expect(none.map(\.model) == [nil, nil])
    }

    @Test func aListThatFitsNeitherIsRefusedWithTheCounts() {
        guard case .failure(let refusal) = TaskAttempts.plan(count: 3, name: "n", slug: "n", branch: "n",
                                                             models: ["a", "b"], drivers: []) else {
            Issue.record("two models for three attempts went through")
            return
        }
        #expect(refusal.message.contains("2 models for 3 attempts"))
        guard case .failure(let one) = TaskAttempts.plan(count: 1, name: "n", slug: "n", branch: "n", models: [], drivers: []) else {
            Issue.record("one attempt is not a plan")
            return
        }
        #expect(one.message.contains("2 or more"))
        #expect(throws: TaskAttempts.Refusal.self) {
            try TaskAttempts.plan(count: 10, name: "n", slug: "n", branch: "n", models: [], drivers: []).get()
        }
    }

    /// The point of the refusal: the number, so the caller lowers N or archives something.
    @Test func theBudgetRefusalSaysHowManyWouldFit() {
        #expect(AutomationPolicy.attemptsRefusal(count: 3, open: 2, limit: 4) == "3 attempts asked, but agents may open 2 more tasks (2 of 4 open)")
        #expect(AutomationPolicy.attemptsRefusal(count: 2, open: 3, limit: 4) == "2 attempts asked, but agents may open 1 more task (3 of 4 open)")
        #expect(AutomationPolicy.attemptsRefusal(count: 2, open: 2, limit: 4) == nil)
        #expect(AutomationPolicy.attemptsRefusal(count: 2, open: 6, limit: 4)?.contains("0 more tasks") == true)
    }

    @Test func theBudgetCountsEveryAttempt() {
        let three = ControlCall.taskNew(TaskNewParams(prompt: "x", attempts: 3))
        #expect(AutomationPolicy.cost(of: three) == AutomationLoad(tasks: 3, threads: 3))
        let cold = ControlCall.taskNew(TaskNewParams(prompt: "x", openThread: false, attempts: 2))
        #expect(AutomationPolicy.cost(of: cold) == AutomationLoad(tasks: 2, threads: 0))
        let policy = AutomationPolicy(settings: AutomationSettings(maxAgentTasks: 4))
        let thread = ThreadID(rawValue: "3f9a2c17be04")!
        guard case .refuse(let error) = policy.decide(three, from: .thread(thread, depth: 0), load: AutomationLoad(tasks: 2)) else {
            Issue.record("three attempts with two slots left went through")
            return
        }
        #expect(error.message.contains("3 attempts asked"))
        #expect(error.message.contains("2 more tasks"))
        #expect(policy.decide(three, from: .thread(thread, depth: 0), load: AutomationLoad(tasks: 1)) == .allow)
    }

    @Test func theCommandLineTakesAttemptsModelsAndDrivers() throws {
        guard case .call(let call, _) = try ScopeCLI.parse(["task", "new", "try it", "--attempts", "3", "--models", "opus,sonnet, haiku",
                                                              "--drivers=claude-code"]) else {
            Issue.record("not a call")
            return
        }
        #expect(call == .taskNew(TaskNewParams(prompt: "try it", attempts: 3, models: ["opus", "sonnet", "haiku"], drivers: ["claude-code"])))
        #expect(throws: ScopeCLI.UsageError.self) { try ScopeCLI.parse(["task", "new", "try it", "--attempts", "many"]) }
    }

    @Test func anOlderClientSendsNoAttempts() throws {
        let json = Data(#"{"prompt":"fix it"}"#.utf8)
        let params = try JSONDecoder().decode(TaskNewParams.self, from: json)
        #expect(params.attempts == 1)
        #expect(params.models.isEmpty)
    }

    @Test func testsRunIsReadOffTheReplyBestEffort() {
        let reply = """
        ## Done

        Added the parser and its tests.
        - `swift test --filter SlugTests`: **12 tests passed**, 0 failed
        - Build green
        """
        #expect(TaskAttempts.testsRun(in: reply) == "swift test --filter SlugTests: 12 tests passed, 0 failed")
        #expect(TaskAttempts.testsRun(in: "All suites pass after the change.") == "All suites pass after the change.")
        #expect(TaskAttempts.testsRun(in: "I changed three files.") == nil)
        #expect(TaskAttempts.testsRun(in: nil) == nil)
    }

    @Test func theExcerptKeepsTheFirstLinesWorthReading() {
        #expect(TaskAttempts.excerpt("\n\n# Report\n\nline 2\n", lines: 2) == "# Report\nline 2")
        #expect(TaskAttempts.excerpt("   ") == nil)
        #expect(TaskAttempts.excerpt(String(repeating: "x", count: 600), limit: 10) == "xxxxxxxxx…")
    }

    @Test func durationsReadAtAGlance() {
        #expect(TaskAttempts.duration(0) == "—")
        #expect(TaskAttempts.duration(47) == "47s")
        #expect(TaskAttempts.duration(200) == "3m 20s")
        #expect(TaskAttempts.duration(3900) == "1h 05m")
    }

    /// 1..N picks the left side, ⇧1..N the right, 0 the base on the right; a digit past N does nothing.
    @Test func digitsPickTheSidesOfTheDiff() {
        var selection = TaskAttempts.Selection.initial
        #expect(selection == TaskAttempts.Selection(left: 1, right: nil))
        selection = selection.pressing(digit: 2, shift: false, count: 3)!
        #expect(selection == TaskAttempts.Selection(left: 2, right: nil))
        selection = selection.pressing(digit: 3, shift: true, count: 3)!
        #expect(selection == TaskAttempts.Selection(left: 2, right: 3))
        #expect(selection.pressing(digit: 4, shift: false, count: 3) == nil)
        #expect(selection.pressing(digit: 0, shift: false, count: 3) == TaskAttempts.Selection(left: 2, right: nil))
    }

    @Test func theColumnSaysWhatChanged() {
        let quiet = TaskAttempts.Column(id: "a", index: 1, name: "n", branch: "b", status: "Running")
        #expect(quiet.changes == "no changes")
        let busy = TaskAttempts.Column(id: "a", index: 1, name: "n", branch: "b", status: "Done", additions: 12, deletions: 3)
        #expect(busy.changes == "+12 −3")
    }

    @Test func theRecordKeepsItsAttemptAcrossEncoding() throws {
        var record = TaskRecord(scopeID: ScopeID(rawValue: "s"), scopeRoot: "/r", scopeSlug: "s", name: "n · attempt 1",
                                slug: "n-a1", branch: "feat/n-a1", root: "/root",
                                attempt: TaskAttempt(group: "g", index: 1, count: 2, baseName: "n", baseBranch: "feat/n"))
        record.attemptsKept = TaskAttemptsKept(count: 2, at: Date(timeIntervalSince1970: 1), otherBranches: ["feat/n-a2"])
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(TaskRecord.self, from: data)
        #expect(back.attempt == record.attempt)
        #expect(back.attemptsKept?.otherBranches == ["feat/n-a2"])
    }

    /// Keeping one posts one Inbox item on the kept task, naming the branches the others left behind; it goes with
    /// the archive window, and never for a task archived since.
    @Test func keepingOneAttemptIsOneInboxItem() {
        let scope = ScopeID(rawValue: "s")
        let id = TaskID(rawValue: "3f9a2c17be04")!
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        let kept = Inbox.TaskInput(id: id, scopeID: scope, name: "Refresh tokens",
                                   attemptsKept: TaskAttemptsKept(count: 3, at: at, otherBranches: ["feat/r-a1", "feat/r-a3"]))
        let items = Inbox.items(threads: [], tasks: [kept], now: at.addingTimeInterval(60))
        #expect(items.count == 1)
        #expect(items[0].kind == .attemptKept)
        #expect(items[0].title == "Refresh tokens")
        #expect(items[0].detail == "kept out of 3 attempts · 2 archived · branches kept: feat/r-a1, feat/r-a3")
        #expect(!items[0].kind.isThreadItem)
        #expect(Inbox.items(threads: [], tasks: [kept], now: at.addingTimeInterval(Inbox.archivedWindow + 1)).isEmpty)
        var archived = kept
        archived.archivedAt = at.addingTimeInterval(120)
        #expect(Inbox.items(threads: [], tasks: [archived], now: at.addingTimeInterval(180)).isEmpty)
        // Done (e) dismisses it against its fingerprint, like any task item.
        let dismissed = Inbox.Dismissals(fingerprints: [items[0].id: items[0].fingerprint])
        #expect(Inbox.items(threads: [], tasks: [kept], dismissed: dismissed, now: at.addingTimeInterval(60)).isEmpty)
    }
}
