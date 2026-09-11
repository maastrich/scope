import SwiftUI
import ScopeTasks

/// Glyph and colour of each `TaskStatus`. Every status has its own symbol *shape*: the row must read in greyscale,
/// for a colour-blind eye, and on the accent-blue selection fill, where colour alone says nothing. Filled variants
/// keep enough ink at 12 pt to stay legible there.
enum TaskStatusStyle {
    static func symbol(_ status: TaskStatus) -> String {
        switch status {
        case .waiting(.permission): "hand.raised.fill"
        case .waiting(.input): "questionmark.bubble.fill"
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
        case .changed: "plusminus.circle.fill"
        case .clean: "arrow.triangle.branch"
        }
    }

    static func color(_ status: TaskStatus) -> AnyShapeStyle {
        switch status {
        case .waiting: AnyShapeStyle(ThreadStateStyle.waiting)
        case .running: AnyShapeStyle(ThreadStateStyle.running)
        case .done: AnyShapeStyle(ThreadStateStyle.done)
        case .setupFailed, .checksFailing: AnyShapeStyle(PullRequestStyle.failing)
        case .conflicted, .checksRunning: AnyShapeStyle(PullRequestStyle.pending)
        case .checksPassed: AnyShapeStyle(PullRequestStyle.passing)
        case .setupRunning, .draft, .pullRequestOpen, .changed: AnyShapeStyle(.secondary)
        case .clean: AnyShapeStyle(.tertiary)
        }
    }
}

/// The leading glyph of a task row, in the 16 pt slot the thread rows give their driver icon.
struct TaskStatusGlyph: View {
    var status: TaskStatus
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: TaskStatusStyle.symbol(status))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(TaskStatusStyle.color(status))
            .frame(width: 16)
            .accessibilityLabel(status.label)
    }
}

/// Horizontal metrics shared by every sidebar row, so task, loose-group and thread rows line up in one column
/// whatever the sidebar width.
enum SidebarMetrics {
    /// The disclosure chevron's slot (drawn or blank) plus the row spacing: a nested row is indented by exactly
    /// this, so its icon sits under its parent's glyph and its title under its parent's name.
    static let indent: CGFloat = 19
    /// Room the hover controls take over the trailing edge of a row.
    static let hoverControlsWidth: CGFloat = 44
}

extension View {
    /// Fades the trailing `width` points of a row out while `active`, so hover controls can be drawn on top without
    /// reserving any width for them when they are not there. A mask, not a background, so it works on any fill —
    /// the sidebar ground and the selection alike.
    func trailingFade(_ active: Bool, width: CGFloat, keeping kept: CGFloat = 0) -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                if active {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 14)
                    Color.clear.frame(width: width)
                    if kept > 0 { Color.black.frame(width: kept) }
                }
            }
        }
    }
}
