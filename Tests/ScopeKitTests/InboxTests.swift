import Foundation
import Testing
@testable import ScopeCore
@testable import ScopeGit
@testable import ScopeTasks

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let other = ScopeID(rawValue: "1a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let prURL = URL(string: "https://github.com/acme/api/pull/12")!

private func thread(_ id: String, _ state: ThreadState, at minutes: Double, scope: ScopeID = acme, text: String? = nil,
                    task: TaskID? = nil) -> Inbox.ThreadInput {
    Inbox.ThreadInput(id: ThreadID(rawValue: id)!, scopeID: scope, taskID: task, title: "thread \(id.prefix(2))",
                      state: state, since: t0.addingTimeInterval(minutes * 60), text: text)
}

private func task(_ id: String, scope: ScopeID = acme, state: PullRequest.State = .open, checks: PullRequest.Checks = .passing,
                  mergeable: PullRequest.Mergeable = .mergeable, draft: Bool = false, failing: [String] = [],
                  updated minutes: Double = 0, archivedAt: Date? = nil, dismantling: Bool = false,
                  pullRequest: Bool = true) -> Inbox.TaskInput {
    Inbox.TaskInput(
        id: TaskID(rawValue: id)!, scopeID: scope, name: "task \(id.prefix(2))",
        pullRequest: pullRequest ? .init(number: 12, title: "Add the inbox", url: prURL, state: state, checks: checks,
                                         mergeable: mergeable, isDraft: draft, failingChecks: failing,
                                         updatedAt: t0.addingTimeInterval(minutes * 60)) : nil,
        archivedAt: archivedAt, isDismantling: dismantling)
}

@Suite struct InboxTests {
    @Test func onlyThreadsThatNeedTheOwnerAreListed() {
        let items = Inbox.items(threads: [
            thread("aaaaaaaaaaa1", .waiting(reason: .input), at: 1, text: "Which branch?"),
            thread("aaaaaaaaaaa2", .waiting(reason: .permission), at: 2),
            thread("aaaaaaaaaaa3", .done, at: 3, text: "\n## Summary\nAll **tests** pass.\n"),
            thread("aaaaaaaaaaa4", .failed, at: 4, text: "rate limited"),
            thread("aaaaaaaaaaa5", .running, at: 5),
            thread("aaaaaaaaaaa6", .idle, at: 6),
            thread("aaaaaaaaaaa7", .exited, at: 7),
        ], tasks: [], now: t0)
        #expect(items.map(\.kind) == [.failure, .reply, .permission, .question])
        #expect(items.first { $0.kind == .reply }?.detail == "Summary")
        #expect(items.first { $0.kind == .question }?.detail == "Which branch?")
    }

    @Test func aPullRequestIsListedWhenReadyOrFailing() {
        let ready = Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1")], now: t0)
        #expect(ready.map(\.kind) == [.readyToMerge])
        #expect(ready[0].pullRequestURL == prURL)

        let failing = Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1", checks: .failing, failing: ["lint", "test"])], now: t0)
        #expect(failing.map(\.kind) == [.checksFailing])
        #expect(failing[0].detail == "#12 failing: lint, test")

        // A failing check wins even on a conflicting pull request: it is what the thread has to fix first.
        #expect(Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1", checks: .failing, mergeable: .conflicting)], now: t0)
            .map(\.kind) == [.checksFailing])
    }

    @Test func aPullRequestNotYetReadyIsNotListed() {
        for input in [task("bbbbbbbbbbb1", checks: .pending), task("bbbbbbbbbbb1", mergeable: .conflicting),
                      task("bbbbbbbbbbb1", mergeable: .unknown), task("bbbbbbbbbbb1", draft: true),
                      task("bbbbbbbbbbb1", state: .merged), task("bbbbbbbbbbb1", state: .closed),
                      task("bbbbbbbbbbb1", pullRequest: false), task("bbbbbbbbbbb1", dismantling: true)] {
            #expect(Inbox.items(threads: [], tasks: [input], now: t0).isEmpty)
        }
    }

    @Test func aTaskArchivedOnItsMergeStaysForItsWindow() {
        let archived = t0.addingTimeInterval(-3600)
        let items = Inbox.items(threads: [], tasks: [task("ccccccccccc1", state: .merged, archivedAt: archived)], now: t0)
        #expect(items.map(\.kind) == [.archivedOnMerge])
        #expect(items[0].at == archived)

        let late = t0.addingTimeInterval(Inbox.archivedWindow)
        #expect(Inbox.items(threads: [], tasks: [task("ccccccccccc1", state: .merged, archivedAt: archived)], now: late).isEmpty)
        // Archived without a merge: dropped work, nothing to restore from here.
        #expect(Inbox.items(threads: [], tasks: [task("ccccccccccc1", state: .closed, archivedAt: archived)], now: t0).isEmpty)
        #expect(Inbox.items(threads: [], tasks: [task("ccccccccccc1", state: .open, archivedAt: archived)], now: t0).isEmpty)
    }

    @Test func oneItemPerThreadAndPerTaskPullRequest() {
        let items = Inbox.items(
            threads: [thread("aaaaaaaaaaa1", .done, at: 1), thread("aaaaaaaaaaa1", .waiting(reason: .input), at: 5)],
            tasks: [task("bbbbbbbbbbb1", updated: 2), task("bbbbbbbbbbb1", checks: .failing, updated: 4)], now: t0)
        #expect(items.count == 2)
        // The newer report of the same thing wins.
        #expect(Set(items.map(\.kind)) == [.question, .checksFailing])
    }

    @Test func groupsPutTheScopeWithTheNewestItemFirst() {
        let items = Inbox.items(threads: [
            thread("aaaaaaaaaaa1", .done, at: 1, scope: acme),
            thread("aaaaaaaaaaa2", .done, at: 9, scope: other),
            thread("aaaaaaaaaaa3", .done, at: 5, scope: acme),
        ], tasks: [], now: t0)
        let groups = Inbox.groups(items, scopeOrder: [acme, other])
        #expect(groups.map(\.scopeID) == [other, acme])
        #expect(groups[1].items.map(\.threadID?.rawValue) == ["aaaaaaaaaaa3", "aaaaaaaaaaa1"])
        #expect(Inbox.drawnOrder(items).map(\.threadID?.rawValue) == ["aaaaaaaaaaa2", "aaaaaaaaaaa3", "aaaaaaaaaaa1"])
    }

    @Test func scopeOrderBreaksTies() {
        let items = Inbox.items(threads: [thread("aaaaaaaaaaa1", .done, at: 1, scope: acme),
                                          thread("aaaaaaaaaaa2", .done, at: 1, scope: other)], tasks: [], now: t0)
        #expect(Inbox.groups(items, scopeOrder: [other, acme]).map(\.scopeID) == [other, acme])
        #expect(Inbox.groups(items, scopeOrder: [acme, other]).map(\.scopeID) == [acme, other])
    }

    @Test func aDismissedTaskItemStaysAwayUntilItChanges() {
        let failing = task("bbbbbbbbbbb1", checks: .failing, failing: ["lint"])
        var dismissed = Inbox.Dismissals()
        dismissed.dismiss(Inbox.items(threads: [], tasks: [failing], now: t0)[0])
        #expect(Inbox.items(threads: [], tasks: [failing], dismissed: dismissed, now: t0).isEmpty)

        // Another check failing is news.
        let other = task("bbbbbbbbbbb1", checks: .failing, failing: ["lint", "test"])
        #expect(Inbox.items(threads: [], tasks: [other], dismissed: dismissed, now: t0).count == 1)
        // Green: ready to merge is news too.
        #expect(Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1")], dismissed: dismissed, now: t0).map(\.kind) == [.readyToMerge])
    }

    @Test func pruningLetsTheSameFailureComeBackAfterAGreenRun() {
        let failing = task("bbbbbbbbbbb1", checks: .failing, failing: ["lint"])
        var dismissed = Inbox.Dismissals()
        dismissed.dismiss(Inbox.items(threads: [], tasks: [failing], now: t0)[0])

        // Still failing: the dismissal is kept.
        dismissed = dismissed.pruned(keeping: Inbox.items(threads: [], tasks: [failing], now: t0))
        #expect(dismissed.fingerprints.count == 1)
        // Green, the app prunes against what it now sees: the dismissal goes.
        dismissed = dismissed.pruned(keeping: Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1", checks: .pending)], now: t0))
        #expect(dismissed.fingerprints.isEmpty)
        #expect(Inbox.items(threads: [], tasks: [failing], dismissed: dismissed, now: t0).count == 1)
    }

    @Test func aDismissalTheAppCannotJudgeIsKept() {
        var dismissed = Inbox.Dismissals()
        dismissed.dismiss(Inbox.items(threads: [], tasks: [task("bbbbbbbbbbb1")], now: t0)[0])
        // Just launched: the pull request is not read yet, so no item, but nothing is known either.
        #expect(dismissed.pruned(keeping: [], judged: { _ in false }).fingerprints.count == 1)
        #expect(dismissed.pruned(keeping: []).fingerprints.isEmpty)
    }

    @Test func threadItemsAreNeverDismissedHere() {
        var dismissed = Inbox.Dismissals()
        let item = Inbox.items(threads: [thread("aaaaaaaaaaa1", .done, at: 1)], tasks: [], now: t0)[0]
        dismissed.dismiss(item)
        #expect(dismissed.fingerprints.isEmpty)
    }

    @Test func aRestoredTaskLeavesWithItsArchive() {
        let archived = task("ccccccccccc1", state: .merged, archivedAt: t0)
        #expect(Inbox.items(threads: [], tasks: [archived], now: t0).count == 1)
        #expect(Inbox.items(threads: [], tasks: [task("ccccccccccc1", state: .merged)], now: t0).isEmpty)
    }

    @Test func headlineSkipsDecorationAndCuts() {
        #expect(Inbox.headline("\n\n> **Done.** Merged it.") == "Done. Merged it.")
        #expect(Inbox.headline("- item") == "item")
        #expect(Inbox.headline("   \n---\n") == nil)
        #expect(Inbox.headline(nil) == nil)
        #expect(Inbox.headline(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaa…")
    }

    @Test func dismissalsRoundTripThroughTheStore() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = InboxDismissalStore(home: home)
        #expect(await store.load() == Inbox.Dismissals())
        await store.save(Inbox.Dismissals(fingerprints: ["task:x:pr": "readyToMerge#12"]))
        #expect(await store.load().fingerprints == ["task:x:pr": "readyToMerge#12"])
    }

    @Test func aScheduleRunIsListedUntilReadOrThreeDays() {
        let run = ScheduleRun(at: t0, outcome: .replied, summary: "\n## Red checks\n\n**api** #12 fails lint.", thread: "ccccccccccc1")
        let input = Inbox.ScheduleInput(id: "0badf00d", scopeID: acme, name: "Morning", run: run,
                                        threadID: ThreadID(rawValue: "ccccccccccc1"))
        let items = Inbox.items(threads: [], tasks: [], schedules: [input], now: t0.addingTimeInterval(60))
        #expect(items.map(\.kind) == [.scheduleRan])
        #expect(items[0].title == "Schedule Morning ran" && items[0].detail == "Red checks")
        #expect(items[0].threadID?.rawValue == "ccccccccccc1" && items[0].id == "schedule:0badf00d")
        // Marked read: gone until the next run; gone anyway after the window.
        var dismissed = Inbox.Dismissals()
        dismissed.dismiss(items[0])
        #expect(Inbox.items(threads: [], tasks: [], schedules: [input], dismissed: dismissed, now: t0.addingTimeInterval(60)).isEmpty)
        var later = input
        later.run.at = t0.addingTimeInterval(3600)
        #expect(Inbox.items(threads: [], tasks: [], schedules: [later], dismissed: dismissed, now: t0.addingTimeInterval(3700)).count == 1)
        #expect(Inbox.items(threads: [], tasks: [], schedules: [input], now: t0.addingTimeInterval(Inbox.scheduleWindow + 1)).isEmpty)
        // A run that never went says why; one without a reply yet says so.
        var failed = input
        failed.run = ScheduleRun(at: t0, outcome: .failed, summary: "no orchestrator")
        #expect(Inbox.items(threads: [], tasks: [], schedules: [failed], now: t0).first?.detail == "did not run: no orchestrator")
        var silent = input
        silent.run = ScheduleRun(at: t0, outcome: .noReply, thread: "ccccccccccc1")
        #expect(Inbox.items(threads: [], tasks: [], schedules: [silent], now: t0).first?.detail == "no reply yet — open the thread")
    }
}
