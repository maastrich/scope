import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct SidebarTaskRowPolicyTests {
    @Test func aCompactRowGetsItsSecondLineOnlyWhileWaitingOrWorking() {
        for status in [TaskStatus.waiting(.input), .waiting(.permission), .failed, .running, .setupRunning, .checksFailing, .conflicted] {
            #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: status), "\(status)")
        }
        for status in [TaskStatus.done, .checksPassed, .merged, .draft, .pullRequestOpen, .changed, .clean] {
            #expect(!SidebarTaskRowPolicy.showsSecondLine(rows: .compact, status: status), "\(status)")
        }
    }

    @Test func aDetailedRowAlwaysHasTwoLines() {
        for status in TaskStatus.precedence {
            #expect(SidebarTaskRowPolicy.showsSecondLine(rows: .detailed, status: status), "\(status)")
        }
    }

    @Test func aBusyCompactRowIsAsTallAsADetailedOne() {
        #expect(SidebarTaskRowPolicy.height(rows: .compact, status: .running) == SidebarRowLayout.detailedHeight)
        #expect(SidebarTaskRowPolicy.height(rows: .compact, status: .clean) == SidebarRowLayout.compactHeight)
        #expect(SidebarTaskRowPolicy.height(rows: .detailed, status: .clean) == SidebarRowLayout.detailedHeight)
    }

    @Test func onlyAOneLineMergedRowShowsTheChip() {
        #expect(SidebarTaskRowPolicy.trailing(status: .merged, secondLine: false) == .mergedChip)
        #expect(SidebarTaskRowPolicy.trailing(status: .merged, secondLine: true) == .stateDot)
        for status in TaskStatus.precedence where status != .merged {
            #expect(SidebarTaskRowPolicy.trailing(status: status, secondLine: false) == .stateDot, "\(status)")
        }
    }

    @Test func sectionsComeMostPressingFirstWithTheirCounts() {
        let sections = SidebarGroup.sections([.quiet, .needsYou, .working, .quiet, .needsYou, .dormant])
        #expect(sections == [
            .init(group: .needsYou, count: 2),
            .init(group: .working, count: 1),
            .init(group: .quiet, count: 2),
            .init(group: .dormant, count: 1),
        ])
    }

    @Test func anEmptyGroupHasNoHeader() {
        #expect(SidebarGroup.sections([]).isEmpty)
        #expect(SidebarGroup.sections([.finished]).map(\.group) == [.finished])
    }
}
