import Testing
@testable import ScopeCore

@Suite struct SidebarRowLayoutTests {
    @Test func aNestedRowIsIndentedByExactlyADisclosureSlot() {
        #expect(SidebarRowLayout.indent == SidebarRowLayout.disclosureSlot + SidebarRowLayout.spacing)
    }

    /// A task and the loose-threads group open with a disclosure slot; the threads nested under either are indented
    /// one level instead. All of them must put their title in the same column, under the parent's title.
    @Test func groupTaskAndNestedThreadShareTheirColumns() {
        let task = SidebarRowLayout.titleColumn(depth: 0, disclosure: true)
        let group = SidebarRowLayout.titleColumn(depth: 0, disclosure: true)
        let nestedThread = SidebarRowLayout.titleColumn(depth: 1, disclosure: false)
        #expect(task == group)
        #expect(task == nestedThread)
    }

    @Test func aRowWithoutDisclosureStartsAtTheEdge() {
        #expect(SidebarRowLayout.titleColumn(depth: 0, disclosure: false) == 0)
    }

    /// The rule hangs from the centre of the parent's chevron and ends, with its tick, before the nested title.
    @Test func theRuleHangsFromTheChevronLeftOfTheNestedTitle() {
        let rule = SidebarRowLayout.ruleColumn(parentDepth: 0)
        #expect(rule == SidebarRowLayout.disclosureSlot / 2)
        #expect(rule + SidebarRowLayout.ruleTick < SidebarRowLayout.titleColumn(depth: 1, disclosure: false))
        #expect(SidebarRowLayout.ruleColumn(parentDepth: 1) == SidebarRowLayout.indent + SidebarRowLayout.disclosureSlot / 2)
    }

    @Test func rowHeightsFollowTheSetting() {
        #expect(SidebarRowLayout.height(detailed: false) == 28)
        #expect(SidebarRowLayout.height(detailed: true) == 42)
    }

    /// The pulse ring grows to 2.1× the dot: the column must hold it (the halo is clipped to the column), and the
    /// column must end inside the selection fill with a point to spare.
    @Test func thePulsingDotStaysInsideItsColumnAndTheSelection() {
        #expect(SidebarRowLayout.stateDotColumn >= SidebarRowLayout.stateDot * 2.1)
        #expect(SidebarRowLayout.rowInset >= SidebarRowLayout.selectionInset + 2)
    }

    /// Three 16 pt icons in a 3 pt wash with 2 pt between them are 70 pt, more than the 62 the row used to clear:
    /// whatever the controls measure, the cleared span is all of it.
    @Test func theClearedSpanCoversTheMeasuredControls() {
        let fade = SidebarRowLayout.HoverFade(controls: 70)
        #expect(fade.hidden == 70)
        #expect(fade.clearFrom == SidebarRowLayout.keptUnderHover + 70)
        #expect(fade.fadeFrom == fade.clearFrom + SidebarRowLayout.fadeRamp)
    }

    @Test func theStateDotStaysDrawnUnderHover() {
        let fade = SidebarRowLayout.HoverFade(controls: 22)
        #expect(fade.kept == SidebarRowLayout.stateDotColumn + SidebarRowLayout.spacing)
        #expect(fade.kept < fade.clearFrom)
    }

    @Test func unmeasuredControlsClearNothing() {
        let fade = SidebarRowLayout.HoverFade(controls: -1)
        #expect(fade.hidden == 0)
        #expect(fade.clearFrom == fade.kept)
    }

    /// The plan rides on the caption, after what the agent is doing; nothing is added when there is no plan in
    /// progress, and a caption with nothing else says the plan alone.
    @Test func thePlanSummaryEndsTheCaption() {
        #expect(SidebarRowLayout.caption("Running the tests", planSummary: "3/7 steps") == "Running the tests · 3/7 steps")
        #expect(SidebarRowLayout.caption("Running the tests", planSummary: nil) == "Running the tests")
        #expect(SidebarRowLayout.caption("Running the tests", planSummary: "") == "Running the tests")
        #expect(SidebarRowLayout.caption("", planSummary: "3/7 steps") == "3/7 steps")
    }
}
