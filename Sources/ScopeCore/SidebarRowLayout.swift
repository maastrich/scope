import Foundation

/// The arithmetic every sidebar row shares, so a group, a task and a thread put their glyph, their title and their
/// state dot in the same three columns. Pure numbers: the app draws with them, the tests hold them together.
///
/// A row reads, left to right: an optional disclosure slot, the glyph slot, the title, then the trailing column —
/// whatever the row counts, and the state dot at the very end. Hover controls are drawn over the end of the title
/// and the counts, never over the dot, which says something the pointer does not change.
public enum SidebarRowLayout {
    /// The disclosure chevron's slot, drawn or blank. A chevron button's hover wash may overflow it; layout counts
    /// only the slot, or a row with a chevron would sit further right than one without.
    public static let disclosureSlot: Double = 12
    /// The leading glyph's slot: a task's status, a thread's driver icon, a group's icon.
    public static let glyphSlot: Double = 16
    /// Between every item of a row.
    public static let spacing: Double = 7
    /// What one level of nesting adds: exactly a disclosure slot and its spacing, so a nested row's glyph sits
    /// under its parent's glyph and the chevron alone says "child of".
    public static let indent = disclosureSlot + spacing
    /// The trailing state dot, and the blank that stands in for it on a row with nothing to report.
    public static let stateDot: Double = 8
    /// Over this many points the text fades out before the hover controls begin.
    public static let fadeRamp: Double = 14

    /// Height of a one-line row (Settings ▸ Sidebar ▸ Rows ▸ Compact).
    public static let compactHeight: Double = 28
    /// Height of a row that carries a second line (Settings ▸ Sidebar ▸ Rows ▸ Detailed).
    public static let detailedHeight: Double = 42

    public static func height(detailed: Bool) -> Double {
        detailed ? detailedHeight : compactHeight
    }

    /// Where the glyph column starts, from the row's leading edge. A row that opens with a disclosure slot (a task,
    /// a group) puts its glyph after it; a thread has none and is indented by `depth` instead.
    public static func glyphColumn(depth: Int, disclosure: Bool) -> Double {
        Double(depth) * indent + (disclosure ? disclosureSlot + spacing : 0)
    }

    /// Where the title column starts.
    public static func titleColumn(depth: Int, disclosure: Bool) -> Double {
        glyphColumn(depth: depth, disclosure: disclosure) + glyphSlot + spacing
    }

    /// What stays drawn at the trailing edge under the hover controls: the state dot and the gap before it.
    public static let keptUnderHover = stateDot + spacing

    /// The trailing spans of a hovered row, measured from its trailing edge: `kept` stays drawn, `hidden` is cleared
    /// for the controls, and the text fades over `ramp` before that. `controls` is the width the controls actually
    /// laid out at, so the cleared span covers all of them whatever they hold.
    public struct HoverFade: Equatable, Sendable {
        public var kept: Double
        public var hidden: Double
        public var ramp: Double

        public init(controls: Double, kept: Double = SidebarRowLayout.keptUnderHover, ramp: Double = SidebarRowLayout.fadeRamp) {
            self.kept = max(0, kept)
            self.hidden = max(0, controls)
            self.ramp = max(0, ramp)
        }

        /// Distance from the trailing edge at which the text is fully gone.
        public var clearFrom: Double { kept + hidden }
        /// Distance from the trailing edge at which the text starts to fade.
        public var fadeFrom: Double { clearFrom + ramp }
    }
}
