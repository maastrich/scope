import Foundation
import Testing
@testable import ScopeCore

@Suite struct ColumnLayoutTests {
    @Test func defaultsSitInsideTheirRanges() {
        #expect(ColumnLayout.sidebarWidthRange.contains(ColumnLayout.defaultSidebarWidth))
        #expect(ColumnLayout.inspectorWidthRange.contains(ColumnLayout.defaultInspectorWidth))
        #expect(ColumnLayout.viewerShareRange.contains(ColumnLayout.defaultViewerShare))
        #expect(ColumnLayout.defaultViewerShare == 0.5)
    }

    @Test func aDragIsHeldToTheRange() {
        #expect(ColumnLayout.clampSidebarWidth(10) == ColumnLayout.sidebarWidthRange.lowerBound)
        #expect(ColumnLayout.clampSidebarWidth(10_000) == ColumnLayout.sidebarWidthRange.upperBound)
        #expect(ColumnLayout.clampSidebarWidth(300) == 300)
        #expect(ColumnLayout.clampInspectorWidth(0) == ColumnLayout.inspectorWidthRange.lowerBound)
        #expect(ColumnLayout.clampViewerShare(1.5) == ColumnLayout.viewerShareRange.upperBound)
    }

    @Test func aCorruptValueFallsToTheLowerBound() {
        #expect(ColumnLayout.clampSidebarWidth(.nan) == ColumnLayout.sidebarWidthRange.lowerBound)
        #expect(ColumnLayout.clampViewerShare(-.infinity) == ColumnLayout.viewerShareRange.lowerBound)
    }
}
