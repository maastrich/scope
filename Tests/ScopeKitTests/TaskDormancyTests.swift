import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct TaskDormancyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func aTaskQuietForDaysIsIdle() {
        let dormancy = TaskDormancy.classify(lastActivity: daysAgo(4.5), now: now, idleDays: 3, pullRequestState: "open", threads: [.idle])
        #expect(dormancy == .idle(days: 4))
        #expect(dormancy.caption == "idle 4d")
    }

    @Test func recentActivityKeepsItActive() {
        #expect(TaskDormancy.classify(lastActivity: daysAgo(2.9), now: now, idleDays: 3, pullRequestState: nil, threads: []) == .active)
        #expect(TaskDormancy.active.caption == nil)
    }

    @Test func aRunningThreadIsActivityNow() {
        #expect(TaskDormancy.classify(lastActivity: daysAgo(30), now: now, idleDays: 3, pullRequestState: "closed",
                                      threads: [.running]) == .active)
    }

    @Test func aClosedUnmergedPullRequestIsDormantWhateverTheDate() {
        let dormancy = TaskDormancy.classify(lastActivity: now, now: now, idleDays: 3, pullRequestState: "closed", threads: [])
        #expect(dormancy == .pullRequestClosed)
        #expect(dormancy.caption == "PR closed")
    }

    @Test func aMergedPullRequestIsNotDormancy() {
        #expect(TaskDormancy.classify(lastActivity: now, now: now, idleDays: 3, pullRequestState: "merged", threads: []) == .active)
    }

    @Test func zeroDaysNeverCallsATaskIdle() {
        #expect(TaskDormancy.classify(lastActivity: daysAgo(100), now: now, idleDays: 0, pullRequestState: nil, threads: []) == .active)
    }

    @Test func lastActivityIsTheLatestDate() {
        let created = daysAgo(10)
        #expect(TaskDormancy.lastActivity(createdAt: created, threadDates: [nil, daysAgo(5), daysAgo(1)]) == daysAgo(1))
        #expect(TaskDormancy.lastActivity(createdAt: created, threadDates: [nil]) == created)
    }

    @Test func dormantTasksLeaveOnlyTheQuietGroups() {
        let idle = TaskDormancy.idle(days: 5)
        #expect(SidebarGroup(TaskStatus.clean, dormancy: idle) == .dormant)
        #expect(SidebarGroup(TaskStatus.done, dormancy: .pullRequestClosed) == .dormant)
        #expect(SidebarGroup(TaskStatus.waiting(.input), dormancy: idle) == .needsYou)
        #expect(SidebarGroup(TaskStatus.checksRunning, dormancy: idle) == .working)
        #expect(SidebarGroup(TaskStatus.clean, dormancy: .active) == .quiet)
    }
}
