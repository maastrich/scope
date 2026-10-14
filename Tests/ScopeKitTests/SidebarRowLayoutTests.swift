import Testing
@testable import ScopeCore

@Suite struct SidebarRowLayoutTests {
    @Test func aNestedRowIsIndentedByExactlyADisclosureSlot() {
        #expect(SidebarRowLayout.indent == SidebarRowLayout.disclosureSlot + SidebarRowLayout.spacing)
    }

    /// A task and the loose-threads group open with a disclosure slot; the threads nested under either are indented
    /// one level instead. All of them must put their glyph, and their title, in the same column.
    @Test func groupTaskAndNestedThreadShareTheirColumns() {
        let task = SidebarRowLayout.glyphColumn(depth: 0, disclosure: true)
        let group = SidebarRowLayout.glyphColumn(depth: 0, disclosure: true)
        let nestedThread = SidebarRowLayout.glyphColumn(depth: 1, disclosure: false)
        #expect(task == group)
        #expect(task == nestedThread)
        #expect(SidebarRowLayout.titleColumn(depth: 0, disclosure: true)
                == SidebarRowLayout.titleColumn(depth: 1, disclosure: false))
    }

    @Test func theTitleFollowsTheGlyphSlot() {
        #expect(SidebarRowLayout.titleColumn(depth: 0, disclosure: false)
                == SidebarRowLayout.glyphSlot + SidebarRowLayout.spacing)
    }

    @Test func rowHeightsFollowTheSetting() {
        #expect(SidebarRowLayout.height(detailed: false) == 28)
        #expect(SidebarRowLayout.height(detailed: true) == 42)
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
        #expect(fade.kept == SidebarRowLayout.stateDot + SidebarRowLayout.spacing)
        #expect(fade.kept < fade.clearFrom)
    }

    @Test func unmeasuredControlsClearNothing() {
        let fade = SidebarRowLayout.HoverFade(controls: -1)
        #expect(fade.hidden == 0)
        #expect(fade.clearFrom == fade.kept)
    }
}
