import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct SidebarGroupTests {
    @Test func whatTheUserMustActOnComesFirst() {
        for status in [TaskStatus.waiting(.input), .waiting(.permission), .failed, .setupFailed, .conflicted, .checksFailing] {
            #expect(SidebarGroup(status) == .needsYou)
        }
    }

    @Test func whatRunsWithoutTheUserIsWorking() {
        for status in [TaskStatus.running, .setupRunning, .checksRunning] {
            #expect(SidebarGroup(status) == .working)
        }
    }

    @Test func aResultToReadIsFinished() {
        #expect(SidebarGroup(TaskStatus.done) == .finished)
        #expect(SidebarGroup(TaskStatus.checksPassed) == .finished)
    }

    @Test func theRestIsQuiet() {
        for status in [TaskStatus.draft, .pullRequestOpen, .changed, .clean] {
            #expect(SidebarGroup(status) == .quiet)
        }
    }

    @Test func threadsFollowTheSameGroups() {
        #expect(SidebarGroup(ThreadState.waiting(reason: .permission)) == .needsYou)
        #expect(SidebarGroup(ThreadState.failed) == .needsYou)
        #expect(SidebarGroup(ThreadState.running) == .working)
        #expect(SidebarGroup(ThreadState.done) == .finished)
        #expect(SidebarGroup(ThreadState.idle) == .quiet)
        #expect(SidebarGroup(ThreadState.exited) == .quiet)
    }

    @Test func groupsSortMostPressingFirst() {
        #expect(SidebarGroup.allCases.sorted() == [.needsYou, .working, .finished, .quiet, .dormant])
    }

    @Test func sidebarPreferencesDefaultToDetailedRowsAsATree() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.sidebarRows == .detailed)
        #expect(preferences.sidebarArrangement == .tree)
    }
}
