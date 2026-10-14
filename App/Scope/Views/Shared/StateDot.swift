import SwiftUI
import ScopeCore

/// The state dot from the UI direction A legend: an 8 pt filled circle (7 pt inside pills and tabs).
/// `exited` is drawn as a 1.5 pt ring, never filled.
///
/// `waiting` is the exception: a rounded **square**, not a circle. It is the one state that asks something of the
/// user, and the one it must never be confused with — *running*, which asks nothing — sits right beside it in the
/// same column. Distinguishing them by colour alone loses that in greyscale and for the ~8 % of men with a colour
/// vision deficiency, so the shape carries it too.
///
/// `failed` is a diamond, for the same reason: it too wants a look, and must not read as *running* in greyscale.
/// A dot whose driver says it is working (`pulses`) breathes, so "running" never has to be told apart from
/// "alive, nothing known" (a shell) by colour alone.
struct StateDot: View {
    var state: ThreadState
    var size: CGFloat = 8
    var pulses = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnAccent) private var isOnAccent

    var body: some View {
        Group {
            switch state {
            case .exited:
                Circle().strokeBorder(isOnAccent ? Ink.onAccent : ThreadStateStyle.exitedRing, lineWidth: 1.5)
            case .waiting:
                RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(fill)
            case .failed:
                RoundedRectangle(cornerRadius: size / 6, style: .continuous).fill(fill)
                    .rotationEffect(.degrees(45))
                    .scaleEffect(0.8)
            default:
                Circle().fill(fill)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if animatesPulse {
                // Read off the clock, like `ScopeSpinner`: a `withAnimation(.repeatForever)` in `onAppear`
                // animated the layout around the dot too — the toolbar pill changing width as its label changed,
                // a row moving as its thread started — and replayed it at every pulse.
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - (1 - phase) * (1 - phase)
                    Circle()
                        .stroke(fill, lineWidth: 1)
                        .scaleEffect(1 + 1.1 * eased)
                        .opacity(0.8 * (1 - eased))
                }
            }
        }
        .accessibilityLabel(state.displayLabel)
    }

    /// On the accent fill every mark goes white; the shape is what still says which state it is, which is
    /// what the legend was designed for.
    private var fill: Color {
        isOnAccent ? Ink.onAccent : state.dotColor
    }

    private var animatesPulse: Bool {
        pulses && state == .running && !reduceMotion
    }
}

extension ThreadState {
    /// Toolbar pill label: Idle / Running / Needs your answer / Needs permission / Done / Failed / Exited.
    var displayLabel: String { label }

    /// Fill colour of the dot. `exited` has no fill (see `StateDot`), the ring colour is returned for pills.
    var dotColor: Color {
        switch self {
        case .idle: ThreadStateStyle.idle
        case .running: ThreadStateStyle.running
        case .waiting: ThreadStateStyle.waiting
        case .done: ThreadStateStyle.done
        case .failed: ThreadStateStyle.failed
        case .exited: ThreadStateStyle.exitedRing
        }
    }
}

/// The toolbar state pill: 22 pt high, dot + label, quiet grey background.
struct StatePill: View {
    var state: ThreadState
    var pulses = false
    /// Replaces the label when there is more to say (the error of a failed turn).
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            StateDot(state: state, size: 7, pulses: pulses)
            Text(detail ?? state.displayLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Fill.quiet, in: Capsule())
        // A toolbar item is proposed whatever room is left, and the label gave way down to its first letter.
        // The cap is for the error of a failed turn, which can be a paragraph.
        .frame(maxWidth: 320)
        .fixedSize()
    }
}
