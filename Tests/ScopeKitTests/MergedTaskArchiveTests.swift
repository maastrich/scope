import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// Each guard that keeps a merged task open, one at a time, from a task that would otherwise archive.
@Suite struct MergedTaskArchiveTests {
    private let mergedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Merged, one quiet thread whose last turn started before the merge, one clean and pushed sandbox.
    private func settled() -> MergedTaskArchive.Facts {
        MergedTaskArchive.Facts(
            pullRequests: [.init(state: "merged", mergedAt: mergedAt)],
            threads: [.init(state: .done, lastTurnStartedAt: mergedAt.addingTimeInterval(-120))],
            sandboxes: [.init(dirty: false, unpushed: 0)])
    }

    @Test func aSettledTaskArchives() {
        #expect(MergedTaskArchive.decide(settled()) == .archive)
    }

    // MARK: Threads

    @Test func aThreadMidTurnHoldsIt() {
        var facts = settled()
        facts.threads.append(.init(state: .running))
        #expect(MergedTaskArchive.decide(facts) == .hold(.threadBusy))
    }

    @Test func aThreadWaitingForSomeoneHoldsIt() {
        for reason in WaitReason.allCases {
            var facts = settled()
            facts.threads[0].state = .waiting(reason: reason)
            #expect(MergedTaskArchive.decide(facts) == .hold(.threadBusy))
        }
    }

    @Test func aThreadWithSubAgentsStillRunningHoldsIt() {
        // Claude Code ends its turn with "waiting for 2 background agents": idle on the surface, working underneath.
        var facts = settled()
        facts.threads[0] = .init(state: .idle, runningAgents: 2)
        #expect(MergedTaskArchive.decide(facts) == .hold(.threadBusy))
    }

    @Test func aThreadThatFailedLaunchingOrWasCutOffHoldsIt() {
        var failed = settled()
        failed.threads[0].state = .failed
        #expect(MergedTaskArchive.decide(failed) == .hold(.threadBusy))
        var launching = settled()
        launching.threads[0] = .init(state: .idle, launching: true)
        #expect(MergedTaskArchive.decide(launching) == .hold(.threadBusy))
        // Restarted mid-turn: the thread is not back yet, its last turn closed by the restart.
        var cutOff = settled()
        cutOff.threads[0] = .init(state: .exited, interrupted: true)
        #expect(MergedTaskArchive.decide(cutOff) == .hold(.threadBusy))
    }

    // MARK: Children

    @Test func anOpenChildTaskHoldsIt() {
        var facts = settled()
        facts.openChildren = 1
        #expect(MergedTaskArchive.decide(facts) == .hold(.openChildren))
    }

    @Test func openDescendantsAreFoundAllTheWayDownThroughArchivedOnes() {
        let root = TaskID.generate(), child = TaskID.generate(), archived = TaskID.generate()
        let grandchild = TaskID.generate(), stranger = TaskID.generate()
        let tasks: [(id: TaskID, parent: TaskID?, isArchived: Bool)] = [
            (root, nil, false), (child, root, false), (archived, root, true), (grandchild, archived, false),
            (stranger, nil, false),
        ]
        #expect(Set(MergedTaskArchive.openDescendants(of: root, in: tasks)) == [child, grandchild])
        #expect(MergedTaskArchive.openDescendants(of: stranger, in: tasks).isEmpty)
        // Only archived ones below: nothing open.
        #expect(MergedTaskArchive.openDescendants(of: root, in: [(root, nil, false), (archived, root, true)]).isEmpty)
    }

    @Test func aParentCycleEnds() {
        let a = TaskID.generate(), b = TaskID.generate()
        #expect(MergedTaskArchive.openDescendants(of: a, in: [(a, b, false), (b, a, false)]) == [b])
    }

    /// 2026-10-20, 10:26: "Refonte UI" saw its own pull request merge while its thread drove four open tasks.
    @Test func anOrchestratorWhosePullRequestMergedStaysWhileItsChildrenAreOpen() {
        let orchestrator = TaskID.generate()
        let children = (0..<4).map { _ in TaskID.generate() }
        let tasks = [(id: orchestrator, parent: TaskID?.none, isArchived: false)]
            + children.map { (id: $0, parent: Optional(orchestrator), isArchived: false) }
        var facts = settled()
        facts.openChildren = MergedTaskArchive.openDescendants(of: orchestrator, in: tasks).count
        #expect(facts.openChildren == 4)
        #expect(MergedTaskArchive.decide(facts) == .hold(.openChildren))
        // And while its thread is still at it, that alone is enough.
        facts.openChildren = 0
        facts.threads[0].state = .running
        #expect(MergedTaskArchive.decide(facts) != .archive)
    }

    // MARK: Pull requests

    @Test func anOpenPullRequestKeepsIt() {
        var facts = settled()
        facts.pullRequests.append(.init(state: "open"))
        #expect(MergedTaskArchive.decide(facts) == .keep)
        facts.pullRequests[1].state = nil
        #expect(MergedTaskArchive.decide(facts) == .keep)
    }

    @Test func aMergeWithoutItsDateIsNotTrustedYet() {
        var facts = settled()
        facts.pullRequests[0].mergedAt = nil
        #expect(MergedTaskArchive.decide(facts) == .hold(.unknown))
    }

    // MARK: Sandboxes

    @Test func uncommittedChangesHoldIt() {
        var facts = settled()
        facts.sandboxes.append(.init(dirty: true, unpushed: 0))
        #expect(MergedTaskArchive.decide(facts) == .hold(.uncommitted))
    }

    @Test func unpushedCommitsHoldIt() {
        var facts = settled()
        facts.sandboxes.append(.init(dirty: false, unpushed: 3))
        #expect(MergedTaskArchive.decide(facts) == .hold(.unpushed))
    }

    @Test func aSandboxNotMeasuredYetHoldsIt() {
        for sandbox in [MergedTaskArchive.Sandbox(dirty: nil, unpushed: 0), .init(dirty: false, unpushed: nil)] {
            var facts = settled()
            facts.sandboxes.append(sandbox)
            #expect(MergedTaskArchive.decide(facts) == .hold(.unknown))
        }
    }

    // MARK: Work after the merge

    @Test func aTurnStartedAfterTheMergeHoldsIt() {
        var facts = settled()
        facts.threads.append(.init(state: .done, lastTurnStartedAt: mergedAt.addingTimeInterval(60)))
        #expect(MergedTaskArchive.decide(facts) == .hold(.workedAfterMerge))
    }

    @Test func theTurnThatMergedDoesNotCountAsWorkAfterTheMerge() {
        // `gh pr merge` ran inside a turn that started before the merge and ended after it.
        var facts = settled()
        facts.threads[0].lastTurnStartedAt = mergedAt.addingTimeInterval(-30)
        #expect(MergedTaskArchive.decide(facts) == .archive)
    }

    @Test func theLastOfSeveralMergesIsTheOneThatCounts() {
        var facts = settled()
        facts.pullRequests.append(.init(state: "merged", mergedAt: mergedAt.addingTimeInterval(600)))
        facts.threads[0].lastTurnStartedAt = mergedAt.addingTimeInterval(300)
        #expect(MergedTaskArchive.decide(facts) == .archive)
    }
}
