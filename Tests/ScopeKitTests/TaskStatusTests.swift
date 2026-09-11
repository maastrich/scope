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
        case .conflicted: TaskFacts(pullRequest: PullRequestFacts(number: 1, mergeable: .conflicting))
        case .checksFailing: TaskFacts(pullRequest: PullRequestFacts(number: 1, checks: .failing))
        case .checksRunning: TaskFacts(pullRequest: PullRequestFacts(number: 1, checks: .pending))
        case .checksPassed: TaskFacts(pullRequest: PullRequestFacts(number: 1, checks: .passing))
        case .draft: TaskFacts(pullRequest: PullRequestFacts(number: 1, isDraft: true))
        case .pullRequestOpen: TaskFacts(pullRequest: PullRequestFacts(number: 1))
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
        if let pr = b.pullRequest {
            var combined = merged.pullRequest ?? pr
            combined.isDraft = combined.isDraft || pr.isDraft
            if pr.checks != .none { combined.checks = pr.checks }
            if pr.mergeable != .unknown { combined.mergeable = pr.mergeable }
            merged.pullRequest = combined
        }
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
            .checksRunning, .checksPassed, .draft, .pullRequestOpen, .changed, .clean,
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
        let pr = TaskFacts(pullRequest: PullRequestFacts(number: 42, checks: .failing))
        #expect(TaskStatus.summary(.resolve(pr), facts: pr) == "Checks are failing on #42.")
        #expect(TaskStatus.summary(.clean, facts: TaskFacts()) == "Nothing changed on the branch yet.")
    }

    @Test func setupInterruptedByAQuitIsFailedAtNextLaunch() {
        #expect(SetupState.running.normalizedAfterRestart == .failed)
        for state in SetupState.allCases where state != .running {
            #expect(state.normalizedAfterRestart == state)
        }
    }
}
