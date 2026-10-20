import Foundation
import Testing
@testable import ScopeCore

@Suite struct InspectorLayoutTests {
    private typealias Layout = InspectorSectionLayout

    private func items(_ open: [InspectorSection: Double]) -> [Layout.Item] {
        InspectorSection.allCases.map { Layout.Item(section: $0, isOpen: open[$0] != nil, natural: open[$0] ?? 0) }
    }

    private var headers: Double { Double(InspectorSection.allCases.count) * Layout.headerHeight }

    @Test func defaultsOpenTheEnvironmentAndChangesOfATaskAndTheRepositoryOtherwise() {
        let sections = InspectorSections.defaults
        #expect(sections.open(hasTask: true) == [.environment, .delta])
        #expect(sections.open(hasTask: false) == [.base])
        #expect(!sections.isOpen(.files, hasTask: true))
        #expect(!sections.isOpen(.files, hasTask: false))
        #expect(sections.visible == InspectorSection.allCases.filter { $0 != .connectors })
    }

    /// The Plan card is a block about the task, right after Environment: closed at rest, dimmed without a task.
    @Test func thePlanCardIsATaskBlockAfterEnvironment() {
        #expect(InspectorSection.allCases.firstIndex(of: .plan) == InspectorSection.allCases.firstIndex(of: .environment)! + 1)
        #expect(InspectorSection.plan.title == "Plan")
        #expect(InspectorSection.plan.needsTask)
        #expect(!InspectorSection.plan.fills)
        #expect(!InspectorSections.defaults.isOpen(.plan, hasTask: true))
        #expect(!InspectorSections.defaults.isOpen(.plan, hasTask: false))
    }

    /// Connectors is a task block after Context, out of the column until the Cards menu brings it in.
    @Test func theConnectorsCardIsAHiddenTaskBlockAfterContext() {
        #expect(InspectorSection.allCases.firstIndex(of: .connectors) == InspectorSection.allCases.firstIndex(of: .context)! + 1)
        #expect(InspectorSection.connectors.title == "Connectors")
        #expect(InspectorSection.connectors.needsTask)
        #expect(!InspectorSection.connectors.fills)
        #expect(!InspectorSections.defaults.isVisible(.connectors))
        var sections = InspectorSections.defaults
        sections.setVisible(.connectors, true)
        #expect(sections.isVisible(.connectors))
        sections.reset()
        #expect(!sections.isVisible(.connectors))
    }

    /// A place saved before the card existed — `hidden: []` and no `known` — must not suddenly show it.
    @Test func aPlaceSavedBeforeTheConnectorsCardKeepsItHidden() throws {
        let json = Data(#"{"withTask":["delta"],"withoutTask":["base"],"hidden":[]}"#.utf8)
        let sections = try JSONDecoder().decode(InspectorSections.self, from: json)
        #expect(sections.hidden == [.connectors])
        let withOthers = Data(#"{"withTask":[],"withoutTask":[],"hidden":["search"]}"#.utf8)
        #expect(try JSONDecoder().decode(InspectorSections.self, from: withOthers).hidden == [.search, .connectors])
    }

    /// Once a place knows the card, what its owner chose stands: shown stays shown.
    @Test func aConnectorsCardShownByChoiceStaysShown() throws {
        var sections = InspectorSections.defaults
        sections.setVisible(.connectors, true)
        let data = try JSONEncoder().encode(sections)
        let decoded = try JSONDecoder().decode(InspectorSections.self, from: data)
        #expect(decoded.isVisible(.connectors))
        #expect(decoded == sections)
    }

    @Test func aHiddenCardIsNeitherVisibleNorOpen() {
        var sections = InspectorSections.defaults
        sections.setVisible(.delta, false)
        #expect(!sections.isVisible(.delta))
        #expect(!sections.isOpen(.delta, hasTask: true))
        #expect(!sections.visible.contains(.delta))
        // Showing it again finds it open as it was left.
        sections.setVisible(.delta, true)
        #expect(sections.isOpen(.delta, hasTask: true))
    }

    @Test func theLastVisibleCardCannotBeHidden() {
        var sections = InspectorSections.defaults
        for section in InspectorSection.allCases { sections.setVisible(section, false) }
        #expect(sections.visible.count == 1)
    }

    @Test func resetBringsEveryCardBack() {
        var sections = InspectorSections(withTask: [.files], withoutTask: [], hidden: [.context, .artifacts])
        sections.reset()
        #expect(sections == .defaults)
    }

    @Test func titlesAnswerTheQuestionsInSentenceCase() {
        #expect(InspectorSection.delta.title == "Changes")
        #expect(InspectorSection.pullRequest.title == "Pull requests")
        #expect(InspectorSection.base.title == "Repository")
    }

    @Test func aTaskSectionCannotOpenWithoutATask() {
        var sections = InspectorSections.defaults
        sections.setOpen(.delta, true, hasTask: false)
        #expect(sections.withoutTask == [.base])
        #expect(!sections.isOpen(.delta, hasTask: false))
    }

    @Test func theTwoSetsAreIndependent() {
        var sections = InspectorSections.defaults
        sections.setOpen(.files, true, hasTask: false)
        #expect(sections.isOpen(.files, hasTask: false))
        #expect(!sections.isOpen(.files, hasTask: true))
    }

    @Test func decodingDropsUnknownSectionsAndFillsMissingSets() throws {
        let json = Data(#"{"withTask":["delta","graph","task","files"]}"#.utf8)
        let sections = try JSONDecoder().decode(InspectorSections.self, from: json)
        #expect(sections.withTask == [.delta, .files])
        #expect(sections.withoutTask == InspectorSections.defaults.withoutTask)
        #expect(sections.hidden == [.connectors])
    }

    @Test func roundTrips() throws {
        let sections = InspectorSections(withTask: [.environment, .history], withoutTask: [.files], hidden: [.search])
        let data = try JSONEncoder().encode(sections)
        #expect(try JSONDecoder().decode(InspectorSections.self, from: data) == sections)
    }

    @Test func aListTakesEverythingTheHeadersLeave() {
        let heights = Layout.bodyHeights(available: 600, items: items([.delta: 0]), weights: [:])
        #expect(heights == [.delta: 600 - headers])
    }

    @Test func blocksTakeTheirOwnHeightAndListsShareTheRestByWeight() {
        // Tall enough that the lighter list stays above its minimum whatever the number of card headers.
        let available = headers + 60 + 4 * Layout.minimumFill * 2
        let heights = Layout.bodyHeights(available: available, items: items([.base: 60, .delta: 0, .files: 0]),
                                         weights: [.delta: 3, .files: 1])
        let rest = available - headers - 60
        #expect(heights[.base] == 60)
        #expect(abs((heights[.delta] ?? 0) - rest * 0.75) < 0.001)
        #expect(abs((heights[.files] ?? 0) - rest * 0.25) < 0.001)
    }

    @Test func aListNeverGoesUnderItsMinimum() {
        let heights = Layout.bodyHeights(available: 700, items: items([.delta: 0, .files: 0]),
                                         weights: [.delta: 100, .files: 1])
        #expect(heights[.files] == Layout.minimumFill)
        #expect(abs((heights[.delta] ?? 0) + Layout.minimumFill - (700 - headers)) < 0.001)
    }

    @Test func blocksShrinkToLeaveTheListsTheirMinimum() {
        let available = headers + 2 * 100 + Layout.minimumFill
        let heights = Layout.bodyHeights(available: available, items: items([.environment: 200, .pullRequest: 200, .history: 0]),
                                         weights: [:])
        #expect(heights[.environment] == 100)
        #expect(heights[.pullRequest] == 100)
        #expect(heights[.history] == Layout.minimumFill)
    }

    @Test func aShortColumnOverflowsInsteadOfCrushing() {
        let heights = Layout.bodyHeights(available: 200, items: items([.environment: 300, .delta: 0, .files: 0]), weights: [:])
        #expect(heights[.environment] == Layout.minimumBlock)
        #expect(heights[.delta] == Layout.minimumFill)
        #expect(heights[.files] == Layout.minimumFill)
    }

    @Test func closedSectionsGetNoBody() {
        let heights = Layout.bodyHeights(available: 600, items: items([:]), weights: [:])
        #expect(heights.isEmpty)
    }

    @Test func dragMovesHeightBetweenTheTwoListsOnly() {
        let start: [InspectorSection: Double] = [.delta: 200, .files: 200, .history: 100]
        let moved = Layout.resize(heights: start, upper: .delta, lower: .files, by: 50)
        #expect(moved == [.delta: 250, .files: 150, .history: 100])
    }

    @Test func dragStopsAtTheMinimum() {
        let start: [InspectorSection: Double] = [.delta: 200, .files: 200]
        #expect(Layout.resize(heights: start, upper: .delta, lower: .files, by: 1000)[.files] == Layout.minimumFill)
        #expect(Layout.resize(heights: start, upper: .delta, lower: .files, by: -1000)[.delta] == Layout.minimumFill)
    }

    @Test func draggedWeightsReproduceTheDraggedHeights() {
        let items = items([.delta: 0, .files: 0])
        let start = Layout.bodyHeights(available: 600, items: items, weights: [:])
        let weights = Layout.resize(heights: start, upper: .delta, lower: .files, by: 40)
        let after = Layout.bodyHeights(available: 600, items: items, weights: weights)
        #expect(abs((after[.delta] ?? 0) - ((start[.delta] ?? 0) + 40)) < 0.001)
    }

    @Test func aDoubleClickGivesTheTwoListsTheSameHeightAndLeavesTheOthers() {
        let start: [InspectorSection: Double] = [.delta: 300, .files: 100, .history: 150]
        let reset = Layout.equalize(heights: start, upper: .delta, lower: .files)
        #expect(reset == [.delta: 200, .files: 200, .history: 150])
        #expect(Layout.equalize(heights: start, upper: .delta, lower: .search) == start)
    }
}
