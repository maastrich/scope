import Foundation

/// The arithmetic every sidebar row shares, so a group, a task and a thread put their title and their state dot in
/// the same columns. Pure numbers: the app draws with them, the tests hold them together.
///
/// A row reads, left to right: an optional disclosure slot, the title, then the trailing column — one indicator,
/// the state dot or a chip, and nothing else. No leading icon: the terminal on the right already says which driver
/// a thread runs, and the dot says what state it is in. Hover controls are drawn over the end of the title, never
/// over the dot, which says something the pointer does not change.
public enum SidebarRowLayout {
    /// The disclosure chevron's slot, drawn or blank. A chevron button's hover wash may overflow it; layout counts
    /// only the slot, or a row with a chevron would sit further right than one without.
    public static let disclosureSlot: Double = 12
    /// Between every item of a row.
    public static let spacing: Double = 7
    /// What one level of nesting adds: exactly a disclosure slot and its spacing, so a nested row's title sits
    /// under its parent's title and the rule hanging from the chevron says "child of".
    public static let indent = disclosureSlot + spacing
    /// The trailing state dot.
    public static let stateDot: Double = 8
    /// What a pulsing dot's halo may add on each side of it. The dot's column is this wide on both sides so the
    /// animation stays inside the row, and the row's trailing inset keeps the column inside the selection fill.
    public static let stateDotHalo: Double = 5
    /// The trailing column: the dot and its halo, or the blank that stands in for them.
    public static let stateDotColumn = stateDot + 2 * stateDotHalo
    /// Over this many points the text fades out before the hover controls begin.
    public static let fadeRamp: Double = 14
    /// A row's inset from the list's edge on each side; the selection fill is inset `selectionInset` and the
    /// dot's halo must end inside it.
    public static let rowInset: Double = 10
    public static let selectionInset: Double = 6

    /// Height of a one-line row (Settings ▸ Sidebar ▸ Rows ▸ Compact).
    public static let compactHeight: Double = 28
    /// Height of a row that carries a second line (Settings ▸ Sidebar ▸ Rows ▸ Detailed, or a compact row of a task
    /// that is waiting or working).
    public static let detailedHeight: Double = 42

    public static func height(detailed: Bool) -> Double {
        detailed ? detailedHeight : compactHeight
    }

    /// Where the title starts, from the row's leading edge. A row that opens with a disclosure slot (a task, a
    /// group) puts its title after it; a thread has none and is indented by `depth` instead.
    public static func titleColumn(depth: Int, disclosure: Bool) -> Double {
        Double(depth) * indent + (disclosure ? disclosureSlot + spacing : 0)
    }

    /// The 1 px rule under a parent row, at the centre of its chevron, that its nested rows hang from.
    public static func ruleColumn(parentDepth: Int) -> Double {
        Double(parentDepth) * indent + disclosureSlot / 2
    }

    /// The short tick from the rule towards each nested row.
    public static let ruleTick: Double = 5

    /// What stays drawn at the trailing edge under the hover controls: the dot's column and the gap before it.
    public static let keptUnderHover = stateDotColumn + spacing

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
