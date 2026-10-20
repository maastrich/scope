import Foundation
import Testing
@testable import ScopeCore

@Suite struct InspectorPlacementTests {
    private typealias Placement = InspectorPlacement
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func place(_ signals: [InspectorSection: Placement.Signal] = [:], sections: InspectorSections = .defaults,
                       retained: Set<InspectorSection> = [], hasTask: Bool = true) -> Placement.Result {
        Placement.place(sections: sections, hasTask: hasTask, signals: signals, retained: retained, now: now)
    }

    /// A task with nothing to say yet: Overview is empty, Details holds every visible card in its order.
    @Test func aQuietTaskHasAnEmptyOverview() {
        let result = place()
        #expect(result.overview.isEmpty)
        #expect(result.details == [.environment, .context, .plan, .delta, .pullRequest, .subagents, .background, .artifacts,
                                   .base, .files, .search, .history])
        #expect(result.nextChange == nil)
    }

    /// Reference cards never come up by themselves, whatever they hold.
    @Test func referenceCardsStayOnDetails() {
        let result = place([.environment: .content, .context: .content, .files: .content])
        #expect(result.overview.isEmpty)
        #expect(result.details.contains(.environment))
        #expect(result.details.contains(.files))
    }

    /// Cards with content come up in Overview's fixed order, whatever order they got their content in.
    @Test func eventCardsComeUpInAFixedOrder() {
        let result = place([.artifacts: .content, .background: .content, .delta: .content, .plan: .content,
                            .subagents: .content, .pullRequest: .content])
        #expect(result.overview == [.plan, .delta, .pullRequest, .subagents, .background, .artifacts])
        #expect(result.details == [.environment, .context, .base, .files, .search, .history])
        #expect(result.page(of: .delta) == .overview)
        #expect(result.page(of: .files) == .details)
    }

    @Test func onlyTheCardsWithContentComeUp() {
        let result = place([.delta: .content, .pullRequest: .empty])
        #expect(result.overview == [.delta])
        #expect(result.details.contains(.pullRequest))
    }

    /// A card that just went quiet stays with its final state, then goes down when the linger runs out.
    @Test func aCardThatWentQuietLingers() {
        let ended = now.addingTimeInterval(-60)
        let result = place([.background: .init(hasContent: false, endedAt: ended)])
        #expect(result.overview == [.background])
        #expect(result.lingering == [.background])
        #expect(result.nextChange == ended.addingTimeInterval(Placement.linger))

        let later = Placement.place(sections: .defaults, hasTask: true,
                                    signals: [.background: .init(hasContent: false, endedAt: ended)],
                                    now: ended.addingTimeInterval(Placement.linger))
        #expect(later.overview.isEmpty)
        #expect(later.nextChange == nil)
    }

    /// The first linger to run out is when the placement changes next.
    @Test func theNextChangeIsTheFirstLingerToEnd() {
        let early = now.addingTimeInterval(-150)
        let result = place([.background: .init(hasContent: false, endedAt: now.addingTimeInterval(-10)),
                            .subagents: .init(hasContent: false, endedAt: early)])
        #expect(result.overview == [.subagents, .background])
        #expect(result.nextChange == early.addingTimeInterval(Placement.linger))
    }

    /// Something that ended long ago (a relaunch, another task) does not bring the card up.
    @Test func anOldEndDoesNotLinger() {
        let result = place([.subagents: .init(hasContent: false, endedAt: now.addingTimeInterval(-3600))])
        #expect(result.overview.isEmpty)
    }

    /// Content wins over an end: a card running again is not lingering.
    @Test func contentIsNotLingering() {
        let result = place([.background: .init(hasContent: true, endedAt: now.addingTimeInterval(-10))])
        #expect(result.overview == [.background])
        #expect(result.lingering.isEmpty)
        #expect(result.nextChange == nil)
    }

    /// A card the user keeps open stays on Overview however quiet it gets.
    @Test func aRetainedCardStays() {
        let result = place([:], retained: [.plan])
        #expect(result.overview == [.plan])
        #expect(!result.details.contains(.plan))
    }

    /// Retention follows the open cards: an open Overview card is kept, a folded one is let go, a Details card is not
    /// kept just because it is open.
    @Test func retentionFollowsTheOpenCards() {
        let kept = Placement.retained(previous: [], overview: [.plan, .delta], open: [.delta, .files])
        #expect(kept == [.delta])
        let folded = Placement.retained(previous: [.delta, .plan], overview: [], open: [.plan])
        #expect(folded == [.plan])
    }

    /// Pinning keeps a card on Overview even empty, reference cards included, Environment first.
    @Test func pinnedCardsAreOnOverview() {
        var sections = InspectorSections.defaults
        sections.setPinned(.pullRequest, true)
        sections.setPinned(.environment, true)
        sections.setPinned(.files, true)
        let result = place([.delta: .content], sections: sections)
        #expect(result.overview == [.environment, .delta, .pullRequest, .files])
        #expect(!result.details.contains(.environment))
        #expect(!result.details.contains(.files))
    }

    /// A hidden card is on neither page, content or not.
    @Test func hiddenCardsAreNowhere() {
        var sections = InspectorSections.defaults
        sections.setVisible(.background, false)
        let result = place([.background: .content], sections: sections)
        #expect(result.page(of: .background) == nil)
        #expect(result.page(of: .connectors) == nil)
    }

    /// Without a task there is no split: the base checkout's cards, as before.
    @Test func withoutATaskThereIsOnePage() {
        let result = place([.delta: .content], hasTask: false)
        #expect(result.overview == [.base, .files, .search, .history])
        #expect(result.details.isEmpty)
    }

    @Test func demotedCardsAreThoseThatWentDown() {
        let before = place([.delta: .content, .background: .content])
        let after = place([.delta: .content])
        #expect(Placement.demoted(from: before, to: after) == [.background])
        #expect(Placement.demoted(from: after, to: before).isEmpty)
    }

    /// Pinning shows a hidden card; hiding unpins.
    @Test func pinningAndHidingExcludeEachOther() {
        var sections = InspectorSections.defaults
        sections.setPinned(.connectors, true)
        #expect(sections.isVisible(.connectors))
        sections.setVisible(.connectors, false)
        #expect(!sections.isPinned(.connectors))
        sections.setPinned(.plan, true)
        sections.setPinned(.plan, false)
        #expect(!sections.isPinned(.plan))
    }

    /// Pins survive the round trip, and a place written before pins decodes with none.
    @Test func pinsArePersistedAndOptional() throws {
        var sections = InspectorSections.defaults
        sections.setPinned(.plan, true)
        let decoded = try JSONDecoder().decode(InspectorSections.self, from: JSONEncoder().encode(sections))
        #expect(decoded.pinned == [.plan])
        let old = Data(#"{"withTask":["delta"],"withoutTask":["base"],"hidden":[],"known":["connectors"]}"#.utf8)
        #expect(try JSONDecoder().decode(InspectorSections.self, from: old).pinned.isEmpty)
    }

    @Test func everyCardHasAPlaceInBothOrders() {
        #expect(Set(Placement.overviewOrder) == Set(InspectorSection.allCases))
        #expect(Set(Placement.detailsOrder) == Set(InspectorSection.allCases))
        #expect(Placement.overviewOrder.count == InspectorSection.allCases.count)
        #expect(Placement.detailsOrder.count == InspectorSection.allCases.count)
    }
}
