import Foundation
import Testing
@testable import ScopeCore

@Suite struct InspectorLayoutTests {
    private typealias Layout = InspectorSectionLayout

    private func items(_ open: [InspectorSection: Double]) -> [Layout.Item] {
        InspectorSection.allCases.map { Layout.Item(section: $0, isOpen: open[$0] != nil, natural: open[$0] ?? 0) }
    }

    private var headers: Double { Double(InspectorSection.allCases.count) * Layout.headerHeight }

    @Test func defaultsOpenTheChangesOfATaskAndTheBaseOtherwise() {
        let sections = InspectorSections.defaults
        #expect(sections.open(hasTask: true) == [.changes])
        #expect(sections.open(hasTask: false) == [.base])
        #expect(!sections.isOpen(.files, hasTask: true))
        #expect(!sections.isOpen(.files, hasTask: false))
    }

    @Test func aTaskSectionCannotOpenWithoutATask() {
        var sections = InspectorSections.defaults
        sections.setOpen(.changes, true, hasTask: false)
        #expect(sections.withoutTask == [.base])
        #expect(!sections.isOpen(.changes, hasTask: false))
    }

    @Test func theTwoSetsAreIndependent() {
        var sections = InspectorSections.defaults
        sections.setOpen(.files, true, hasTask: false)
        #expect(sections.isOpen(.files, hasTask: false))
        #expect(!sections.isOpen(.files, hasTask: true))
    }

    @Test func decodingDropsUnknownSectionsAndFillsMissingSets() throws {
        let json = Data(#"{"withTask":["changes","graph","files"]}"#.utf8)
        let sections = try JSONDecoder().decode(InspectorSections.self, from: json)
        #expect(sections.withTask == [.changes, .files])
        #expect(sections.withoutTask == InspectorSections.defaults.withoutTask)
    }

    @Test func roundTrips() throws {
        let sections = InspectorSections(withTask: [.task, .history], withoutTask: [.files])
        let data = try JSONEncoder().encode(sections)
        #expect(try JSONDecoder().decode(InspectorSections.self, from: data) == sections)
    }

    @Test func aListTakesEverythingTheHeadersLeave() {
        let heights = Layout.bodyHeights(available: 600, items: items([.changes: 0]), weights: [:])
        #expect(heights == [.changes: 600 - headers])
    }

    @Test func blocksTakeTheirOwnHeightAndListsShareTheRestByWeight() {
        let heights = Layout.bodyHeights(available: 700, items: items([.base: 60, .changes: 0, .files: 0]),
                                         weights: [.changes: 3, .files: 1])
        let rest = 700 - headers - 60
        #expect(heights[.base] == 60)
        #expect(abs((heights[.changes] ?? 0) - rest * 0.75) < 0.001)
        #expect(abs((heights[.files] ?? 0) - rest * 0.25) < 0.001)
    }

    @Test func aListNeverGoesUnderItsMinimum() {
        let heights = Layout.bodyHeights(available: 700, items: items([.changes: 0, .files: 0]),
                                         weights: [.changes: 100, .files: 1])
        #expect(heights[.files] == Layout.minimumFill)
        #expect(abs((heights[.changes] ?? 0) + Layout.minimumFill - (700 - headers)) < 0.001)
    }

    @Test func blocksShrinkToLeaveTheListsTheirMinimum() {
        let available = headers + 2 * 100 + Layout.minimumFill
        let heights = Layout.bodyHeights(available: available, items: items([.task: 200, .pullRequest: 200, .history: 0]),
                                         weights: [:])
        #expect(heights[.task] == 100)
        #expect(heights[.pullRequest] == 100)
        #expect(heights[.history] == Layout.minimumFill)
    }

    @Test func aShortColumnOverflowsInsteadOfCrushing() {
        let heights = Layout.bodyHeights(available: 200, items: items([.task: 300, .changes: 0, .files: 0]), weights: [:])
        #expect(heights[.task] == Layout.minimumBlock)
        #expect(heights[.changes] == Layout.minimumFill)
        #expect(heights[.files] == Layout.minimumFill)
    }

    @Test func closedSectionsGetNoBody() {
        let heights = Layout.bodyHeights(available: 600, items: items([:]), weights: [:])
        #expect(heights.isEmpty)
    }

    @Test func dragMovesHeightBetweenTheTwoListsOnly() {
        let start: [InspectorSection: Double] = [.changes: 200, .files: 200, .history: 100]
        let moved = Layout.resize(heights: start, upper: .changes, lower: .files, by: 50)
        #expect(moved == [.changes: 250, .files: 150, .history: 100])
    }

    @Test func dragStopsAtTheMinimum() {
        let start: [InspectorSection: Double] = [.changes: 200, .files: 200]
        #expect(Layout.resize(heights: start, upper: .changes, lower: .files, by: 1000)[.files] == Layout.minimumFill)
        #expect(Layout.resize(heights: start, upper: .changes, lower: .files, by: -1000)[.changes] == Layout.minimumFill)
    }

    @Test func draggedWeightsReproduceTheDraggedHeights() {
        let items = items([.changes: 0, .files: 0])
        let start = Layout.bodyHeights(available: 600, items: items, weights: [:])
        let weights = Layout.resize(heights: start, upper: .changes, lower: .files, by: 40)
        let after = Layout.bodyHeights(available: 600, items: items, weights: weights)
        #expect(abs((after[.changes] ?? 0) - ((start[.changes] ?? 0) + 40)) < 0.001)
    }

    @Test func viewerShareStaysUsable() {
        #expect(Layout.clampViewerShare(0.05) == 0.2)
        #expect(Layout.clampViewerShare(0.95) == 0.8)
        #expect(Layout.clampViewerShare(0.5) == 0.5)
    }
}
