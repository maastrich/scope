import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// What Scope does when main moves under a task: the decision from plain facts, the fold of several repositories,
/// and the words the agent reads.
@Suite struct FollowMainTests {
    private func lag(behind: Int, conflicts: [String] = [], known: Bool = true, head: String = "h1",
                     subjects: [String] = []) -> TaskLag {
        TaskLag(repos: [".": BranchLag(upstream: "origin/main", upstreamHead: head, ahead: 2, behind: behind,
                                       conflicts: conflicts, conflictsKnown: known, behindSubjects: subjects)])
    }

    @Test func upToDateAndHeldAndSettledAreLeftAlone() {
        #expect(FollowMain.decide(.init(lag: lag(behind: 0)), mode: .askAgent) == .leave("up to date with main"))
        #expect(FollowMain.decide(.init(lag: nil), mode: .rebaseWhenClean) == .leave("up to date with main"))
        let held = FollowMain.decide(.init(lag: lag(behind: 3, conflicts: ["a"]), holdBranch: true), mode: .askAgent)
        #expect(held == .leave("the branch is held: Don't rebase automatically"))
        // The hold stands on demand too: the user set it.
        #expect(FollowMain.decide(.init(lag: lag(behind: 3), holdBranch: true), mode: .askAgent, onDemand: true) == held)
        let settled = FollowMain.decide(.init(lag: lag(behind: 3, conflicts: ["a"]), pullRequestSettled: true), mode: .askAgent)
        #expect(settled == .leave("its pull request is merged or closed"))
    }

    @Test func askTheAgentOnConflictsOncePerHead() {
        let facts = FollowMain.Facts(lag: lag(behind: 3, conflicts: ["a.swift"]))
        #expect(FollowMain.decide(facts, mode: .askAgent) == .askAgent)
        #expect(FollowMain.decide(facts, mode: .rebaseWhenClean) == .askAgent)
        var seen = facts
        seen.actedOnHead = seen.lag?.upstreamHead
        #expect(FollowMain.decide(seen, mode: .askAgent) == .leave("already acted on this head of main"))
        // Main moves again: asked again. On demand: asked whatever was remembered.
        var moved = seen
        moved.lag = lag(behind: 4, conflicts: ["a.swift"], head: "h2")
        #expect(FollowMain.decide(moved, mode: .askAgent) == .askAgent)
        #expect(FollowMain.decide(seen, mode: .askAgent, onDemand: true) == .askAgent)
    }

    @Test func gitHubSayingConflictingIsEnoughToAsk() {
        let facts = FollowMain.Facts(lag: lag(behind: 0), pullRequestMergeable: .conflicting)
        #expect(FollowMain.decide(facts, mode: .askAgent) == .askAgent)
        #expect(FollowMain.decide(.init(lag: nil, pullRequestMergeable: .conflicting), mode: .rebaseWhenClean) == .askAgent)
        #expect(FollowMain.decide(.init(lag: lag(behind: 0), pullRequestMergeable: .mergeable), mode: .askAgent) == .leave("up to date with main"))
    }

    @Test func aCleanLagIsTheAgentsBusinessUnlessThePreferenceRebases() {
        let facts = FollowMain.Facts(lag: lag(behind: 2))
        #expect(FollowMain.decide(facts, mode: .askAgent) == .leave("behind without conflicts: the agent rebases when it pushes"))
        #expect(FollowMain.decide(facts, mode: .rebaseWhenClean) == .rebase)
        var busy = facts
        busy.threadRunning = true
        #expect(FollowMain.decide(busy, mode: .rebaseWhenClean) == .leave("a thread is at work in the task"))
        // A dry merge that could not run is not a clean lag.
        #expect(FollowMain.decide(.init(lag: lag(behind: 2, known: false)), mode: .rebaseWhenClean) == .askAgent)
    }

    @Test func neverOnlyShowsButOnDemandStillActs() {
        let clean = FollowMain.Facts(lag: lag(behind: 2))
        let conflicting = FollowMain.Facts(lag: lag(behind: 2, conflicts: ["x"]))
        #expect(FollowMain.decide(clean, mode: .never) == .leave("Settings ▸ Tasks ▸ When main moves is Never"))
        #expect(FollowMain.decide(conflicting, mode: .never) == .leave("Settings ▸ Tasks ▸ When main moves is Never"))
        #expect(FollowMain.decide(clean, mode: .never, onDemand: true) == .rebase)
        #expect(FollowMain.decide(clean, mode: .askAgent, onDemand: true) == .rebase)
        #expect(FollowMain.decide(conflicting, mode: .never, onDemand: true) == .askAgent)
    }

    @Test func severalRepositoriesFoldIntoOneLag() {
        let folded = TaskLag(repos: [
            "api": BranchLag(upstream: "origin/main", upstreamHead: "aaa", behind: 4, conflicts: ["a.swift", "b.swift"],
                             behindSubjects: ["x (#12)"]),
            "web": BranchLag(upstream: "origin/main", upstreamHead: "bbb", behind: 1, behindSubjects: ["y (#15)", "x (#12)"]),
        ])
        #expect(folded.behind == 4 && folded.conflicts == 2 && folded.hasConflicts)
        #expect(folded.upstreamHead == "api:aaa web:bbb")
        #expect(folded.mergedPullRequests == [12, 15])
        #expect(folded.conflictedPaths == ["api/a.swift", "api/b.swift"])
        #expect(folded.caption == "behind main by 4 · conflicts in 2 files")
        #expect(lag(behind: 1).caption == "behind main by 1")
        #expect(lag(behind: 0).caption == "up to date with main")
        #expect(lag(behind: 2, known: false).caption == "behind main by 2 · conflicts unknown")
        #expect(TaskLag().caption == nil)
    }

    @Test func mainTouchingTheTasksFilesAsksAnIdleThreadBeforeItConflicts() {
        var overlapping = lag(behind: 2)
        overlapping.repos["."]?.overlaps = ["Sources/A.swift"]
        let open = FollowMain.Facts(lag: overlapping, pullRequestMergeable: .mergeable)
        #expect(FollowMain.decide(open, mode: .askAgent) == .askAgentPreventive)
        #expect(overlapping.overlappingPaths == ["Sources/A.swift"])
        // Without an open pull request, at work, or once per head: left alone.
        #expect(FollowMain.decide(.init(lag: overlapping), mode: .askAgent) != .askAgentPreventive)
        #expect(FollowMain.decide(.init(lag: overlapping, pullRequestMergeable: .mergeable, threadRunning: true), mode: .askAgent)
                != .askAgentPreventive)
        #expect(FollowMain.decide(.init(lag: overlapping, pullRequestMergeable: .mergeable, actedOnHead: overlapping.upstreamHead),
                                  mode: .askAgent) != .askAgentPreventive)
        // No shared file: the agent updates when it pushes.
        #expect(FollowMain.decide(.init(lag: lag(behind: 2), pullRequestMergeable: .mergeable), mode: .askAgent) != .askAgentPreventive)
        // Rebase-when-clean rebases itself; never means never.
        #expect(FollowMain.decide(open, mode: .rebaseWhenClean) == .rebase)
        #expect(FollowMain.decide(open, mode: .never) != .askAgentPreventive)
    }

    @Test func overlappingPathsAreTheIntersectionOfBothDiffs() {
        #expect(BranchLag.overlapping("a.swift\nb.swift\n", "b.swift\nc.swift") == ["b.swift"])
        #expect(BranchLag.overlapping("", "a") == [])
    }

    @Test func theRecordKeepsTheHoldAndTheHead() throws {
        var record = TaskRecord(scopeID: .generate(), scopeRoot: "/s", scopeSlug: "acme", name: "T", slug: "t", branch: "feat/t", root: "/r")
        record.holdBranch = true
        record.followedMainHead = ".:abc"
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: data)
        #expect(decoded.holdBranch && decoded.followedMainHead == ".:abc")
        // A record written before the fields existed reads as not held, never acted on.
        let old = try JSONDecoder().decode(TaskRecord.self, from: Data(#"""
        {"version":1,"id":"0123456789ab","scopeID":"abcdef012345","slug":"t","branch":"feat/t","root":"/r"}
        """#.utf8))
        #expect(!old.holdBranch && old.followedMainHead == nil)
    }

    @Test func thePreferenceDecodesLenientlyAndTheScopeMayOverride() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"followMain":"rebaseWhenClean"}"#.utf8))
        #expect(preferences.followMain == .rebaseWhenClean)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).followMain == .askAgent)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(#"{"followMain":"whatever"}"#.utf8)).followMain == .askAgent)
        let scope = try JSONDecoder().decode(ScopeDeclaration.self, from: Data(#"""
        {"id":"abcdef012345","path":"/tmp/acme","slug":"acme","followMain":"never"}
        """#.utf8))
        #expect(scope.followMain == .never)
        #expect(ScopeDeclaration(path: "/tmp/x", slug: "x").followMain == nil)
    }
}
