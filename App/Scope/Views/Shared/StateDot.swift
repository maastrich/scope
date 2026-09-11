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
    @State private var pulsePhase = false

    var body: some View {
        Group {
            switch state {
            case .exited:
                Circle().strokeBorder(ThreadStateStyle.exitedRing, lineWidth: 1.5)
            case .waiting:
                RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(state.dotColor)
            case .failed:
                RoundedRectangle(cornerRadius: size / 6, style: .continuous).fill(state.dotColor)
                    .rotationEffect(.degrees(45))
                    .scaleEffect(0.8)
            default:
                Circle().fill(state.dotColor)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if animatesPulse {
                Circle()
                    .stroke(state.dotColor, lineWidth: 1)
                    .scaleEffect(pulsePhase ? 2.1 : 1)
                    .opacity(pulsePhase ? 0 : 0.8)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsePhase = true }
                    }
                    .onDisappear { pulsePhase = false }
            }
        }
        .accessibilityLabel(state.displayLabel)
    }

    private var animatesPulse: Bool {
        pulses && state == .running && !reduceMotion
    }
}

/// Colours of the state legend: catalogue colours with light/dark variants, every one at least 3:1 on its
/// ground (WCAG 1.4.11). `done` is pinned to blue rather than the accent so it keeps its meaning under a
/// graphite or red system accent.
enum ThreadStateStyle {
    static let idle = Color("StateIdle")
    static let running = Color("StateRunning")
    static let waiting = Color("StateWaiting")
    static let done = Color("StateDone")
    static let failed = Color("ChecksFailing")
    /// Reads on both the sidebar and the dark terminal.
    static let exitedRing = Color("ExitedRing")
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
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
