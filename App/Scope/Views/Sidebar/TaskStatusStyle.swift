import SwiftUI
import ScopeCore
import ScopeTasks

/// Glyph and colour of each `TaskStatus`. Every status has its own symbol *shape*: the row must read in greyscale,
/// for a colour-blind eye, and on the accent-blue selection fill, where colour alone says nothing. Filled variants
/// keep enough ink at 12 pt to stay legible there.
enum TaskStatusStyle {
    static func symbol(_ status: TaskStatus) -> String {
        switch status {
        case .waiting(.permission): "hand.raised.fill"
        case .waiting(.input): "questionmark.bubble.fill"
        case .failed: "exclamationmark.bubble.fill"
        case .running: "play.circle.fill"
        case .setupRunning: "gearshape.fill"
        case .setupFailed: "exclamationmark.triangle.fill"
        case .done: "flag.fill"
        case .conflicted: "exclamationmark.arrow.triangle.2.circlepath"
        case .checksFailing: "xmark.octagon.fill"
        case .checksRunning: "clock.fill"
        case .checksPassed: "checkmark.seal.fill"
        case .draft: "pencil.circle.fill"
        case .pullRequestOpen: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .changed: "plusminus.circle.fill"
        case .clean: "arrow.triangle.branch"
        }
    }

    static func color(_ status: TaskStatus) -> AnyShapeStyle {
        switch status {
        case .waiting: AnyShapeStyle(ThreadStateStyle.waiting)
        case .running: AnyShapeStyle(ThreadStateStyle.running)
        case .done: AnyShapeStyle(ThreadStateStyle.done)
        case .failed: AnyShapeStyle(ThreadStateStyle.failed)
        case .setupFailed, .checksFailing: AnyShapeStyle(PullRequestStyle.failing)
        case .conflicted, .checksRunning: AnyShapeStyle(PullRequestStyle.pending)
        case .checksPassed, .merged: AnyShapeStyle(PullRequestStyle.passing)
        case .setupRunning, .draft, .pullRequestOpen, .changed: AnyShapeStyle(.secondary)
        case .clean: AnyShapeStyle(.tertiary)
        }
    }
}

/// The glyph of a task's status, where one is still drawn: the hover card and its list of child tasks. The sidebar
/// rows no longer carry it — the dot at the end of the row and the group it sits in say what matters.
struct TaskStatusGlyph: View {
    var status: TaskStatus
    var size: CGFloat = 12
    @Environment(\.isOnAccent) private var isOnAccent

    var body: some View {
        Image(systemName: TaskStatusStyle.symbol(status))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isOnAccent ? AnyShapeStyle(Ink.onAccent) : TaskStatusStyle.color(status))
            .frame(width: 16)
            .accessibilityLabel(status.label)
    }
}

/// `SidebarRowLayout` in the units SwiftUI draws with, so task, loose-group and thread rows line up in one column
/// whatever the sidebar width.
enum SidebarMetrics {
    static let disclosureSlot = CGFloat(SidebarRowLayout.disclosureSlot)
    static let spacing = CGFloat(SidebarRowLayout.spacing)
    static let indent = CGFloat(SidebarRowLayout.indent)
    static let stateDot = CGFloat(SidebarRowLayout.stateDot)
    static let stateDotColumn = CGFloat(SidebarRowLayout.stateDotColumn)
    static let rowInset = CGFloat(SidebarRowLayout.rowInset)
    static let selectionInset = CGFloat(SidebarRowLayout.selectionInset)

    static let keptUnderHover = CGFloat(SidebarRowLayout.keptUnderHover)

    static func rowHeight(detailed: Bool) -> CGFloat {
        CGFloat(SidebarRowLayout.height(detailed: detailed))
    }
}

/// The chevron of a row that expands, or its blank slot. Both are exactly `SidebarMetrics.disclosureSlot` wide: the
/// button's hover wash overflows the slot rather than widening it, which used to push a group's or a multi-thread
/// task's glyph and title 6 pt right of every other row's.
struct SidebarDisclosure: View {
    /// Nil draws the blank slot.
    var isExpanded: Bool?
    var accessibilityLabel: String? = nil
    var toggle: () -> Void = {}

    var body: some View {
        if let isExpanded {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: SidebarMetrics.disclosureSlot, height: SidebarMetrics.disclosureSlot)
            }
            .buttonStyle(.iconTight)
            .frame(width: SidebarMetrics.disclosureSlot)
            .help(isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(accessibilityLabel ?? (isExpanded ? "Collapse" : "Expand"))
        } else {
            Color.clear.frame(width: SidebarMetrics.disclosureSlot, height: SidebarMetrics.disclosureSlot)
        }
    }
}

/// The state dot at the end of a sidebar row, or the blank that holds its column when there is nothing to report.
///
/// The dot sits in a column wide enough for its pulse, and the column clips: the halo used to run past the rounded
/// edge of the selection fill and come out cut.
struct SidebarStateDot: View {
    var state: ThreadState?
    var pulses = false

    var body: some View {
        Group {
            if let state {
                StateDot(state: state, size: SidebarMetrics.stateDot, pulses: pulses)
            } else {
                Color.clear
            }
        }
        .frame(width: SidebarMetrics.stateDotColumn, height: SidebarMetrics.stateDotColumn)
        .clipped()
    }
}

/// What a one-line row of a task whose pull requests have all landed shows in place of the dot: the dot would say
/// *idle* about a task whose only news is that it is done.
struct SidebarMergedChip: View {
    var body: some View {
        // Whole or not at all: the name gives way first.
        Chip(text: "merged", tint: PullRequestStyle.passing)
            .fixedSize()
            .accessibilityLabel("Pull request merged")
    }
}

/// Where a nested row hangs: under which parent, and whether it is the last one (the rule stops at its tick).
struct SidebarNesting: Equatable {
    var parentDepth: Int
    var isLast: Bool
}

/// The 1 px rule from a parent row's chevron down its nested rows, with a tick towards each (`SidebarRowLayout`).
/// Drawn in device pixels, so it is a hairline on every display.
private struct SidebarNestedRule: View {
    var nesting: SidebarNesting
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let pixel = 1 / scale
            let x = (CGFloat(SidebarRowLayout.ruleColumn(parentDepth: nesting.parentDepth)) * scale).rounded() / scale + pixel / 2
            let middle = (geometry.size.height / 2 * scale).rounded() / scale + pixel / 2
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: nesting.isLast ? middle : geometry.size.height))
                path.move(to: CGPoint(x: x, y: middle))
                path.addLine(to: CGPoint(x: x + CGFloat(SidebarRowLayout.ruleTick), y: middle))
            }
            .stroke(Surface.stroke, lineWidth: pixel)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Hangs the row from its parent's rule when it is nested (`SidebarNesting`); nothing otherwise.
    @ViewBuilder
    func sidebarNested(_ nesting: SidebarNesting?) -> some View {
        if let nesting {
            background { SidebarNestedRule(nesting: nesting) }
        } else {
            self
        }
    }

    /// Draws `controls` over the trailing end of a row while `active`, left of the state dot, and fades the text out
    /// under them. The controls are always laid out — invisible and inert at rest — so their real width is known
    /// before the first hover: the cleared span is what they measure, not a guess that drifts when one is added.
    /// `kept` is the trailing span that stays drawn: the dot's column by default, a chip's width when the row ends
    /// with one.
    func sidebarHoverControls<Controls: View>(_ active: Bool, kept: CGFloat = SidebarMetrics.keptUnderHover,
                                              @ViewBuilder controls: () -> Controls) -> some View {
        modifier(SidebarHoverControls(active: active, kept: kept, controls: controls()))
    }

    /// Fades the trailing span of a row out, so hover controls can be drawn on top without reserving any width for
    /// them when they are not there. A mask, not a background, so it works on any fill — the sidebar ground and the
    /// selection alike.
    fileprivate func trailingFade(_ active: Bool, _ fade: SidebarRowLayout.HoverFade) -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                if active {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade.ramp)
                    Color.clear.frame(width: fade.hidden)
                    Color.black.frame(width: fade.kept)
                }
            }
        }
    }
}

private struct SidebarHoverControls<Controls: View>: ViewModifier {
    var active: Bool
    var kept: CGFloat
    var controls: Controls
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let fade = SidebarRowLayout.HoverFade(controls: width, kept: kept)
        content
            .trailingFade(active, fade)
            .overlay(alignment: .trailing) {
                controls
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .padding(.trailing, fade.kept)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    // Out of the key loop too, or Full Keyboard Access tabs onto a button nobody can see.
                    .disabled(!active)
                    .accessibilityHidden(!active)
            }
    }
}
