import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// What a summary of past work keeps, how it judges each task, and what it leaves out.
@Suite struct ActivitySummaryTests {
    static let zone = TimeZone(identifier: "Europe/London")!

    static func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// 5–11 October 2026.
    static let week = ActivityPeriod(label: "last week", since: date(10, 5, 0), until: date(10, 12, 0))
    static let acme = ActivitySummary.ScopeRef(id: "A1", slug: "acme", name: "Acme", root: "/work/acme")

    static func task(_ id: String, slug: String, scope: String = "A1", scopeSlug: String = "acme", topic: String? = nil,
                     created: Date, archived: Date? = nil, prompt: String? = nil,
                     pr: TaskSnapshot.PullRequest? = nil, byAgent: Bool = false) -> TaskSnapshot {
        TaskSnapshot(id: id, name: slug.replacingOccurrences(of: "-", with: " ").capitalized, slug: slug, scopeID: scope,
                     scopeSlug: scopeSlug, scopeName: scopeSlug.capitalized, branch: "feat/\(slug)", topic: topic,
                     repos: ["api"], createdAt: created, archivedAt: archived, prompt: prompt, pullRequest: pr,
                     createdByAgent: byAgent)
    }

    static func thread(_ id: String, task: String? = nil, scope: String = "A1", root: String = "/work/acme", created: Date,
                       launched: Date? = nil, resident: String? = nil) -> ThreadSnapshot {
        ThreadSnapshot(id: id, title: "t-\(id)", driverID: "claude-code", scopeID: scope, scopeRoot: root, taskID: task,
                       createdAt: created, lastLaunchedAt: launched, launchCount: 1, session: "s-\(id)", resident: resident)
    }

    static func pr(_ number: Int, _ state: String?) -> TaskSnapshot.PullRequest {
        TaskSnapshot.PullRequest(number: number, url: URL(string: "https://github.com/acme/api/pull/\(number)")!,
                                 title: "PR \(number)", state: state)
    }

    // MARK: Outcomes

    @Test func theOutcomeComesFromTheRecordAlone() {
        func classify(archived: Bool = false, closed: Bool = false, _ state: String? = nil, pr: Bool = false) -> TaskOutcome {
            TaskOutcome.classify(archived: archived, closed: closed, pullRequestState: state, hasPullRequest: pr || state != nil)
        }
        #expect(classify() == .active)
        #expect(classify("open") == .active)
        #expect(classify("merged") == .merged, "merged even before anyone archives it")
        #expect(classify(archived: true, "merged") == .merged)
        #expect(classify(closed: true, "merged") == .merged, "closed after the merge, with --delete-branch")
        #expect(classify(archived: true, "open") == .delivered)
        #expect(classify(archived: true, pr: true) == .delivered, "a state never seen is not a merge")
        #expect(classify(archived: true, "closed") == .abandoned)
        #expect(classify(closed: true) == .abandoned)
        #expect(classify(archived: true) == .archived, "no pull request: done or dropped, Scope cannot tell")
    }

    // MARK: What falls in the period

    @Test func aTaskCountsWhenSomethingHappenedToItInThePeriod() {
        let tasks = [
            Self.task("t1", slug: "made-this-week", created: Self.date(10, 6)),
            Self.task("t2", slug: "archived-this-week", created: Self.date(9, 20), archived: Self.date(10, 7)),
            Self.task("t3", slug: "worked-on-this-week", created: Self.date(9, 1)),
            Self.task("t4", slug: "untouched", created: Self.date(9, 1)),
            Self.task("t5", slug: "after", created: Self.date(10, 13)),
        ]
        let threads = [
            Self.thread("h3", task: "t3", created: Self.date(9, 1), launched: Self.date(10, 9)),
            Self.thread("h4", task: "t4", created: Self.date(9, 1), launched: Self.date(9, 2)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: tasks,
                                           threads: threads, history: [])
        #expect(result.scopes.map(\.slug) == ["acme"])
        #expect(Set(result.scopes[0].tasks.map(\.slug)) == ["made-this-week", "archived-this-week", "worked-on-this-week"])
        let worked = result.scopes[0].tasks.first { $0.slug == "worked-on-this-week" }!
        #expect(worked.lastActivity == Self.date(10, 9))
        #expect(worked.threads.map(\.session) == ["s-h3"])
    }

    /// The record is gone; the history is all that says the task existed — and that it was dropped.
    @Test func aClosedTaskComesFromTheHistory() {
        let closed = Self.task("t9", slug: "spike-dropped", created: Self.date(10, 5), prompt: "Try the new parser.")
        let history = [
            HistoryEntry.taskClosed(closed, at: Self.date(10, 8)),
            .threadClosed(Self.thread("h9", task: "t9", created: Self.date(10, 5)), at: Self.date(10, 8)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: [],
                                           threads: [], history: history)
        let task = result.scopes[0].tasks[0]
        #expect(task.outcome == .abandoned)
        #expect(task.closedAt == Self.date(10, 8))
        #expect(task.threads.map(\.closedAt) == [Self.date(10, 8)])
        #expect(result.scopes[0].counts.abandoned == 1)
        #expect(result.historySince == Self.date(10, 8))
    }

    @Test func aLiveRecordBeatsAnOlderCloseOfTheSameTask() {
        let live = Self.task("t1", slug: "back-again", created: Self.date(10, 6))
        let history = [HistoryEntry.taskClosed(live, at: Self.date(10, 7))]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: [live],
                                           threads: [], history: history)
        #expect(result.scopes[0].tasks.count == 1)
        #expect(result.scopes[0].tasks[0].outcome == .active)
    }

    @Test func threadsOutsideTasksAreListedButResidentsAreNot() {
        let threads = [
            Self.thread("r1", created: Self.date(10, 6), resident: "orchestrator"),
            Self.thread("s1", created: Self.date(10, 6)),
            Self.thread("s2", created: Self.date(8, 1), launched: Self.date(8, 2)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: [],
                                           threads: threads, history: [])
        #expect(result.scopes[0].threads.map(\.id) == ["s1"])
        #expect(result.scopes[0].tasks.isEmpty)
    }

    // MARK: Scopes

    @Test func aRemovedScopeKeepsTheNameItsTasksRecorded() {
        let tasks = [
            Self.task("t1", slug: "here", created: Self.date(10, 6)),
            Self.task("t2", slug: "gone", scope: "OLD", scopeSlug: "legacy", created: Self.date(10, 6)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: tasks,
                                           threads: [], history: [])
        #expect(result.scopes.map(\.slug) == ["acme", "legacy"], "declared scopes first")
        #expect(result.scopes.map(\.declared) == [true, false])
        #expect(result.scopes[1].name == "Legacy")
    }

    @Test func aScopeFilterTakesSlugNameOrIdOfDeclaredAndRemovedScopes() {
        let tasks = [
            Self.task("t1", slug: "here", created: Self.date(10, 6)),
            Self.task("t2", slug: "gone", scope: "OLD", scopeSlug: "legacy", created: Self.date(10, 6)),
        ]
        func slugs(_ filter: String) -> [String] {
            ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: tasks, threads: [],
                                  history: [], scopeFilter: filter).scopes.map(\.slug)
        }
        #expect(slugs("acme") == ["acme"])
        #expect(slugs("ACME") == ["acme"])
        #expect(slugs("A1") == ["acme"])
        #expect(slugs("legacy") == ["legacy"])
        #expect(slugs("nowhere").isEmpty)
    }

    // MARK: Order and noise

    @Test func tasksAreGroupedByTopicThenByDate() {
        let tasks = [
            Self.task("t1", slug: "loose", created: Self.date(10, 5)),
            Self.task("t2", slug: "b-second", topic: "Billing", created: Self.date(10, 7)),
            Self.task("t3", slug: "a-first", topic: "auth", created: Self.date(10, 8)),
            Self.task("t4", slug: "b-first", topic: "billing", created: Self.date(10, 6)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: tasks,
                                           threads: [], history: [])
        #expect(result.scopes[0].tasks.map(\.slug) == ["a-first", "b-first", "b-second", "loose"])
    }

    @Test func aBriefIsItsOpeningAndNeverTheWholePage() {
        let prompt = """
        # Task: rewrite the importer

        ---
        Rewrite   the CSV importer so it streams rows instead of loading the file.
        Keep the public API.
        """ + String(repeating: " More context.", count: 100)
        let brief = ActivitySummary.excerpt(prompt)!
        #expect(brief.hasPrefix("Rewrite the CSV importer so it streams rows instead of loading the file. Keep the public API."))
        #expect(brief.count <= ActivitySummary.briefLimit + 1)
        #expect(brief.hasSuffix("…"))
        #expect(!brief.hasSuffix(" …"), "cut at a word")
        let twoParagraphs = "# Goal\n\nShip the importer.\nStreaming only.\n\n## Context\n\nLong background."
        #expect(ActivitySummary.excerpt(twoParagraphs) == "Ship the importer. Streaming only.", "the first paragraph only")
        #expect(ActivitySummary.excerpt("# only a heading") == nil)
        #expect(ActivitySummary.excerpt("Short.") == "Short.")
    }

    @Test func theDetailOfOneTaskHasItsWholeBriefWhateverThePeriod() {
        let prompt = String(repeating: "line\n", count: 300)
        let old = Self.task("t1", slug: "long-ago", created: Self.date(3, 1), archived: Self.date(3, 2), prompt: prompt)
        let detail = ActivitySummary.detail(of: "long-ago", timeZone: Self.zone, period: Self.week, scopes: [Self.acme],
                                            tasks: [old], threads: [], history: [])
        #expect(detail?.detail?.prompt == prompt)
        #expect(detail?.detail?.scope == "acme")
        #expect(detail?.scopes.isEmpty == true)
        #expect(ActivitySummary.detail(of: "t1", timeZone: Self.zone, period: Self.week, scopes: [], tasks: [old], threads: [],
                                       history: [])?.detail?.task.slug == "long-ago")
        #expect(ActivitySummary.detail(of: "nope", timeZone: Self.zone, period: Self.week, scopes: [], tasks: [old],
                                       threads: [], history: []) == nil)
    }

    @Test func theLimitsSayWhenTheHistoryStarts() {
        let none = ActivitySummary.limits(history: [])
        #expect(none.last!.contains("No task or thread has been closed"))
        let some = ActivitySummary.limits(history: [.threadClosed(Self.thread("x", created: Self.date(10, 1)), at: Self.date(10, 2))])
        #expect(some.last!.contains("2026-10-02"))
        #expect(some.count == ActivitySummary.fixedLimits.count + 1)
    }

    // MARK: Rendering

    @Test func theTextNamesTheDatesTheOutcomesAndTheLimits() {
        let tasks = [
            Self.task("t1", slug: "auth-refresh", topic: "auth", created: Self.date(10, 6), archived: Self.date(10, 8),
                      prompt: "Refresh tokens on 401.", pr: Self.pr(42, "merged")),
            Self.task("t2", slug: "half-done", created: Self.date(10, 9), archived: Self.date(10, 9), pr: Self.pr(43, nil)),
        ]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: tasks,
                                           threads: [], history: [])
        let text = CLIRenderer.text(.summary(result))
        #expect(text.hasPrefix("last week: 2026-10-05 → 2026-10-11 (Europe/London)"))
        #expect(text.contains("acme — 2 tasks: 1 merged, 1 delivered"))
        #expect(text.contains("  topic: auth"))
        #expect(text.contains("merged    Auth Refresh [auth-refresh] · #42 merged · created 2026-10-06, archived 2026-10-08"))
        #expect(text.contains("Refresh tokens on 401."))
        #expect(text.contains("#43 (state unknown)"))
        #expect(text.contains("note: Of what was said in a task's threads, Scope keeps only each thread's last answer"))
    }

    @Test func eachTaskSaysHowLongItsAgentsWorkedAndHowLongItWaitedOnYou() {
        var timed = Self.task("t1", slug: "timed", created: Self.date(10, 6), archived: Self.date(10, 7))
        timed.agentSeconds = 3 * 3600 + 20 * 60
        timed.waitingSeconds = 20 * 60
        var closed = Self.task("t2", slug: "closed-timed", created: Self.date(10, 6))
        closed.agentSeconds = 90
        closed.waitingSeconds = 0
        let untimed = Self.task("t3", slug: "untimed", created: Self.date(10, 6))
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: [timed, untimed],
                                           threads: [], history: [.taskClosed(closed, at: Self.date(10, 8))])
        let tasks = Dictionary(uniqueKeysWithValues: result.scopes[0].tasks.map { ($0.slug, $0) })
        #expect(tasks["timed"]?.agentSeconds == 12_000)
        #expect(tasks["timed"]?.waitingSeconds == 1_200)
        #expect(tasks["closed-timed"]?.agentSeconds == 90, "a closed task keeps the totals it left in the history")
        #expect(tasks["untimed"]?.agentSeconds == nil)

        let text = CLIRenderer.text(.summary(result))
        #expect(text.contains("agent 3 h 20, waited on you 20 min"))
        #expect(!text.contains("Untimed [untimed] · created 2026-10-06, last active 2026-10-06 · agent"))
        #expect(result.limits.contains { $0.hasPrefix("Agent time adds up") })

        let detail = ActivitySummary.detail(of: "timed", timeZone: Self.zone, period: Self.week, scopes: [Self.acme],
                                            tasks: [timed], threads: [], history: [])
        #expect(CLIRenderer.text(.summary(detail!)).contains("time        agent 3 h 20, waited on you 20 min"))
    }

    @Test func theResultSurvivesTheWire() throws {
        let history = [HistoryEntry.taskClosed(Self.task("t9", slug: "dropped", created: Self.date(10, 5)), at: Self.date(10, 8))]
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme],
                                           tasks: [Self.task("t1", slug: "kept", created: Self.date(10, 6), pr: Self.pr(1, "open"))],
                                           threads: [], history: history)
        let response = ControlResponse.result(id: "abcd", .summary(result))
        let decoded = try ControlResponse.decode(try response.encoded(), method: .summary)
        #expect(decoded.payload == .summary(result))
    }

    // MARK: Kept answers

    static func kept(_ task: String, _ text: String, files: [String] = []) -> TaskDeliverable {
        // Whole seconds: the control wire keeps none of the fraction.
        TaskDeliverable(taskID: task, savedAt: date(10, 8), replies: [.init(threadID: "th-\(task)", title: "Claude", driver: "claude-code",
                                                      text: text, at: date(10, 8))],
                        files: files.map { .init(name: $0, text: "report") })
    }

    @Test func aTaskLineCarriesTheOpeningOfItsKeptAnswer() {
        let study = Self.task("t1", slug: "study", created: Self.date(10, 6), archived: Self.date(10, 8))
        let open = Self.task("t2", slug: "open", created: Self.date(10, 6))
        let result = ActivitySummary.build(period: Self.week, timeZone: Self.zone, scopes: [Self.acme], tasks: [study, open],
                                           threads: [], history: [],
                                           deliverables: ["t1": Self.kept("t1", "## Findings\n\nThe cache is never hit.\n\nDetails…",
                                                                         files: ["REPORT.md"])])
        let tasks = result.scopes[0].tasks
        #expect(tasks[0].answer == "The cache is never hit.")
        #expect(tasks[0].reports == ["REPORT.md"])
        #expect(tasks[1].answer == nil && tasks[1].reports == nil)
        let text = CLIRenderer.text(.summary(result))
        #expect(text.contains("→ The cache is never hit."))
        #expect(text.contains("kept: REPORT.md"))
    }

    @Test func theDetailHasTheKeptAnswersTrimmedFromTheirStart() {
        let long = String(repeating: "x", count: ActivitySummary.detailReplyLimit) + "CONCLUSION"
        let task = Self.task("t1", slug: "study", created: Self.date(10, 6), archived: Self.date(10, 8))
        let result = ActivitySummary.detail(of: "study", timeZone: Self.zone, period: Self.week, scopes: [Self.acme],
                                            tasks: [task], threads: [], history: [], deliverables: ["t1": Self.kept("t1", long)])
        let reply = try? #require(result?.detail?.replies?.first)
        #expect(reply?.text.hasSuffix("CONCLUSION") == true && reply?.text.hasPrefix("…") == true)
        #expect(reply?.text.count == ActivitySummary.detailReplyLimit + 1)
        let text = CLIRenderer.text(.summary(result!))
        #expect(text.contains("last answer of Claude [claude-code]"))
        #expect(text.contains(ThreadTranscript.openMarker))
    }

    @Test func showFindsAClosedTaskAndItsDeliverable() throws {
        let closed = Self.task("t9", slug: "gone", created: Self.date(10, 5), archived: Self.date(10, 7), prompt: "Study the cache.")
        let history = [HistoryEntry.taskClosed(closed, at: Self.date(10, 8))]
        let deliverable = Self.kept("t9", "Never hit.", files: ["REPORT.md"])
        let shown = try #require(ActivitySummary.show("gone", scopes: [Self.acme], tasks: [], threads: [], history: history,
                                                      deliverables: ["t9": deliverable]))
        #expect(shown.scope == "acme" && shown.prompt == "Study the cache." && shown.deliverable == deliverable)
        #expect(shown.task.closedAt == Self.date(10, 8) && shown.notes.isEmpty && shown.untrusted)
        let text = CLIRenderer.text(.taskShow(shown))
        #expect(text.hasPrefix("task gone — Gone (acme)"))
        #expect(text.contains("brief:\nStudy the cache."))
        #expect(text.contains("REPORT.md:\n" + ThreadTranscript.untrustedNotice))
        #expect(text.contains("Never hit."))

        let response = ControlResponse.result(id: "abcd", .taskShow(shown))
        #expect(try ControlResponse.decode(try response.encoded(), method: .taskShow).payload == .taskShow(shown))
    }

    @Test func showSaysWhenNothingIsKeptYet() throws {
        let open = Self.task("t1", slug: "live", created: Self.date(10, 6), prompt: "Do it.")
        let shown = try #require(ActivitySummary.show("live", scopes: [Self.acme], tasks: [open], threads: [], history: [],
                                                      deliverables: [:]))
        #expect(shown.deliverable == nil && shown.notes.first?.contains("kept when it is archived") == true)
        let archived = Self.task("t2", slug: "old", created: Self.date(10, 6), archived: Self.date(10, 7))
        let none = try #require(ActivitySummary.show("old", scopes: [Self.acme], tasks: [archived], threads: [], history: [],
                                                     deliverables: [:]))
        #expect(none.notes.first?.hasPrefix("Nothing was kept") == true)
        #expect(ActivitySummary.show("nope", scopes: [], tasks: [], threads: [], history: [], deliverables: [:]) == nil)
    }
}
