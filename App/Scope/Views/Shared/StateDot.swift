import SwiftUI
import ScopeCore

/// The state dot from the UI direction A legend: an 8 pt filled circle (7 pt inside pills and tabs).
/// `exited` is drawn as a 1.5 pt ring, never filled.
struct StateDot: View {
    var state: ThreadState
    var size: CGFloat = 8

    var body: some View {
        Group {
            if case .exited = state {
                Circle().strokeBorder(ThreadStateStyle.exitedRing, lineWidth: 1.5)
            } else {
                Circle().fill(state.dotColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.displayLabel)
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
    /// Reads on both the sidebar and the dark terminal.
    static let exitedRing = Color("ExitedRing")
}

extension ThreadState {
    /// Toolbar pill label: Idle / Running / Waiting for input / Done / Exited.
    var displayLabel: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waiting(let reason):
            switch reason {
            case .permission: "Waiting for permission"
            default: "Waiting for input"
            }
        case .done: "Done"
        case .exited: "Exited"
        }
    }

    /// Fill colour of the dot. `exited` has no fill (see `StateDot`), the ring colour is returned for pills.
    var dotColor: Color {
        switch self {
        case .idle: ThreadStateStyle.idle
        case .running: ThreadStateStyle.running
        case .waiting: ThreadStateStyle.waiting
        case .done: ThreadStateStyle.done
        case .exited: ThreadStateStyle.exitedRing
        }
    }
}

/// The toolbar state pill: 22 pt high, dot + label, quiet grey background.
struct StatePill: View {
    var state: ThreadState

    var body: some View {
        HStack(spacing: 6) {
            StateDot(state: state, size: 7)
            Text(state.displayLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
