import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite struct TaskStatusTests {
    /// The smallest facts that make `status` true on its own.
    static func facts(for status: TaskStatus) -> TaskFacts {
        switch status {
        case .waiting(let reason): TaskFacts(threads: [.waiting(reason: reason)])
        case .failed: TaskFacts(threads: [.failed])
        case .running: TaskFacts(threads: [.running])
        case .setupRunning: TaskFacts(setup: .running)
        case .setupFailed: TaskFacts(setup: .failed)
        case .done: TaskFacts(threads: [.done])
        case .conflicted: TaskFacts(pullRequests: [PullRequestFacts(number: 1, mergeable: .conflicting)])
        case .checksFailing: TaskFacts(pullRequests: [PullRequestFacts(number: 1, checks: .failing)])
        case .checksRunning: TaskFacts(pullRequests: [PullRequestFacts(number: 1, checks: .pending)])
        case .checksPassed: TaskFacts(pullRequests: [PullRequestFacts(number: 1, checks: .passing)])
        case .draft: TaskFacts(pullRequests: [PullRequestFacts(number: 1, isDraft: true)])
        case .pullRequestOpen: TaskFacts(pullRequests: [PullRequestFacts(number: 1)])
        case .merged: TaskFacts(pullRequests: [PullRequestFacts(number: 1, checks: .passing, state: .merged)])
        case .changed: TaskFacts(additions: 3)
        case .clean: TaskFacts()
        }
    }

    /// Everything two sets of facts say, merged: the union of both states.
    static func merge(_ a: TaskFacts, _ b: TaskFacts) -> TaskFacts {
        var merged = a
        merged.threads += b.threads
        merged.additions += b.additions
        merged.deletions += b.deletions
        merged.isDirty = a.isDirty || b.isDirty
        if b.setup != .notRun { merged.setup = b.setup }
        // Each set's pull requests stay their own: a task that is both conflicted and merged has two of them.
        merged.pullRequests += b.pullRequests
        return merged
    }

    @Test func eachStatusResolvesOnItsOwn() {
        for status in TaskStatus.precedence {
            #expect(TaskStatus.resolve(Self.facts(for: status)) == status, "\(status)")
        }
    }

    /// Every pair of rungs, both ways round: the higher one wins whatever it is combined with.
    @Test func higherRungWinsOverEveryLowerOne() {
        let ladder = TaskStatus.precedence
        for (i, higher) in ladder.enumerated() {
            for lower in ladder[(i + 1)...] {
                let combined = Self.merge(Self.facts(for: lower), Self.facts(for: higher))
                #expect(TaskStatus.resolve(combined) == higher, "\(higher) over \(lower)")
            }
        }
    }

    @Test func precedenceIsTheDocumentedOrder() {
        #expect(TaskStatus.precedence == [
            .waiting(.input), .failed, .running, .setupRunning, .setupFailed, .done, .conflicted, .checksFailing,
            .checksRunning, .checksPassed, .draft, .pullRequestOpen, .merged, .changed, .clean,
        ])
    }

    @Test func waitingKeepsItsReason() {
        let facts = TaskFacts(threads: [.running, .waiting(reason: .permission), .waiting(reason: .input)])
        #expect(TaskStatus.resolve(facts) == .waiting(.permission))
    }

    @Test func exitedAndIdleThreadsSayNothing() {
        #expect(TaskStatus.resolve(TaskFacts(threads: [.exited, .idle])) == .clean)
        #expect(TaskStatus.resolve(TaskFacts(threads: [.exited], isDirty: true)) == .changed)
    }

    @Test func succeededOrSkippedSetupIsQuiet() {
        #expect(TaskStatus.resolve(TaskFacts(setup: .succeeded)) == .clean)
        #expect(TaskStatus.resolve(TaskFacts(setup: .skipped)) == .clean)
    }

    @Test func summaryNamesTheReasonAndTheCounts() {
        let facts = TaskFacts(threads: [.waiting(reason: .permission), .idle], additions: 12, deletions: 3, isDirty: true)
        #expect(TaskStatus.summary(.resolve(facts), facts: facts)
                == "Waiting for your permission in one of its 2 threads; +12 −3, uncommitted work.")
        let pr = TaskFacts(pullRequests: [PullRequestFacts(number: 42, checks: .failing)])
        #expect(TaskStatus.summary(.resolve(pr), facts: pr) == "Checks are failing on #42.")
        #expect(TaskStatus.summary(.clean, facts: TaskFacts()) == "Nothing changed on the branch yet.")
    }

    @Test func setupInterruptedByAQuitIsFailedAtNextLaunch() {
        #expect(SetupState.running.normalizedAfterRestart == .failed)
        for state in SetupState.allCases where state != .running {
            #expect(state.normalizedAfterRestart == state)
        }
    }

    // MARK: Several pull requests

    @Test func theMostPressingOpenPullRequestDecides() {
        let red = PullRequestFacts(number: 41, checks: .failing)
        let green = PullRequestFacts(number: 43, checks: .passing)
        let merged = PullRequestFacts(number: 7, checks: .passing, state: .merged)
        let facts = TaskFacts(pullRequests: [green, red, merged])
        #expect(TaskStatus.resolve(facts) == .checksFailing)
        #expect(facts.pullRequest?.number == 41)
        #expect(TaskStatus.summary(.resolve(facts), facts: facts)
                == "Checks are failing on #41; 3 PRs · 1 merged · 1 checks failing · 1 checks passed.")
        // A conflict outranks red checks; a merged one is never the status while another is open.
        let conflicted = PullRequestFacts(number: 50, checks: .passing, mergeable: .conflicting)
        #expect(TaskStatus.resolve(TaskFacts(pullRequests: [merged, red, conflicted])) == .conflicted)
        #expect(TaskStatus.decisive([merged, green, red])?.number == 41)
    }

    @Test func everyPullRequestSettledSaysMergedOrFallsThrough() {
        let merged = PullRequestFacts(number: 7, checks: .passing, state: .merged)
        let closed = PullRequestFacts(number: 8, checks: .failing, state: .closed)
        #expect(TaskStatus.resolve(TaskFacts(pullRequests: [closed, merged])) == .merged)
        #expect(TaskStatus.summary(.merged, facts: TaskFacts(pullRequests: [closed, merged])).hasPrefix("Every pull request is merged or closed"))
        #expect(TaskStatus.summary(.merged, facts: TaskFacts(pullRequests: [merged])) == "#7 is merged.")
        // Closed without a merge: the red checks of a dropped pull request are nobody's concern; the branch decides.
        #expect(TaskStatus.resolve(TaskFacts(additions: 2, pullRequests: [closed])) == .changed)
        #expect(TaskStatus.resolve(TaskFacts(pullRequests: [closed])) == .clean)
        #expect(SidebarGroup(TaskStatus.merged) == .finished)
    }
}
