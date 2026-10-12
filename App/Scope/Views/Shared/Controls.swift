import SwiftUI

// The app's own controls. Every one of these exists because the AppKit control it replaces is drawn by the
// OS and looks it: a bezelled push button, a segmented picker with a saturated fill, a pop-up with the system
// chevrons. Those are right for a settings window and wrong for a tool whose chrome is its own.
//
// The rules they all follow:
//   - a flat fill or nothing; no bezel, no gradient, no inner shadow
//   - 1px hairline where a boundary is needed, `Surface.stroke`, never a border for decoration
//   - the accent appears on *one* thing at a time — the primary action, or the selected row, not both
//   - 20 / 22 / 26 pt tall, `Radius.sm` or `Radius.md`, and the label carries the meaning
//   - hover answers, because nothing else says these are controls

/// Push buttons. `.primary` is the accent-filled one and there is at most one per surface; `.secondary` is
/// the ordinary one; `.ghost` has no fill until you point at it; `.danger` is secondary with a red label,
/// since a destructive action wants to be found, not to be the loudest thing on screen.
struct ScopeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }

    var kind: Kind = .secondary
    var height: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, kind: kind, height: height)
    }

    /// Not called `Body`: that name collides with the protocol's own associated type, the same trap
    /// `IconButtonStyle` documents. A `ButtonStyle` cannot hold `@State`, and hover is state.
    private struct HoverLabel: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(label)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(fill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay {
                    if stroked {
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(Surface.stroke, lineWidth: 1)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
        }

        private var stroked: Bool {
            kind == .secondary || kind == .danger
        }

        private var label: Color {
            switch kind {
            case .primary: Ink.onAccent
            case .secondary, .ghost: Ink.primary
            case .danger: ThreadStateStyle.failed
            }
        }

        private var fill: Color {
            guard isEnabled else { return kind == .primary ? Color.accentColor : .clear }
            switch kind {
            case .primary:
                return configuration.isPressed ? Color.accentColor.opacity(0.82) : Color.accentColor
            case .secondary, .danger:
                if configuration.isPressed { return Fill.pressed }
                return hovering ? Fill.hover : Fill.quiet
            case .ghost:
                if configuration.isPressed { return Fill.pressed }
                return hovering ? Fill.hover : .clear
            }
        }
    }
}

extension ButtonStyle where Self == ScopeButtonStyle {
    static var scopePrimary: ScopeButtonStyle { ScopeButtonStyle(kind: .primary) }
    static var scopeSecondary: ScopeButtonStyle { ScopeButtonStyle(kind: .secondary) }
    static var scopeGhost: ScopeButtonStyle { ScopeButtonStyle(kind: .ghost) }
    static var scopeDanger: ScopeButtonStyle { ScopeButtonStyle(kind: .danger) }
    /// The 26 pt variant, for a bar that is the only thing on its row.
    static var scopePrimaryLarge: ScopeButtonStyle { ScopeButtonStyle(kind: .primary, height: 26) }
    static var scopeSecondaryLarge: ScopeButtonStyle { ScopeButtonStyle(kind: .secondary, height: 26) }
}

/// A short label on a quiet fill: a branch name, a count, a state, a path fragment. The one shape the app
/// uses for "a value, not an action" — a chip is never clickable unless it is inside a button.
struct Chip: View {
    var text: String
    var tint: Color?
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 10, design: .monospaced) : .system(size: 10, weight: .medium))
            .foregroundStyle(tint ?? Ink.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// The uppercase rule that opens a section — the sidebar groups, the inspector's lists. Small, wide-tracked
/// and tertiary, so it orders the page without competing with anything in it.
struct SectionLabel: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Ink.tertiary)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(height: 22)
    }
}

extension View {
    /// The app's own text-field box: opaque ground, hairline at rest, a 2pt accent ring while it has the
    /// keyboard. `.textFieldStyle(.plain)` strips AppKit's bezel; this puts something back that is ours.
    ///
    /// A modifier rather than a wrapper view, because a field is a row of things — an icon, the text, a clear
    /// button, a shortcut hint — and wrapping that in a container would mean threading its layout through.
    func scopeFieldBox(focused: Bool, height: CGFloat = 24) -> some View {
        padding(.horizontal, 7)
            .frame(height: height)
            .background(Surface.field, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Surface.stroke, lineWidth: focused ? 2 : 1)
            }
    }
}

/// A switch, drawn by us.
///
/// `Toggle` renders as a *checkbox* on macOS unless it sits inside a `Form`, which is how the settings window
/// used to get switches — the grouped form was doing it. Taking the form away took the switches with it, so
/// this puts them back and stops them depending on their container.
struct ScopeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 9) {
                configuration.label
                    .font(.scopeBody)
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                track(configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }

    private func track(_ on: Bool) -> some View {
        Capsule()
            .fill(on ? Color.accentColor : Fill.quiet)
            .overlay { Capsule().strokeBorder(on ? .clear : Surface.stroke, lineWidth: 1) }
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(on ? Ink.onAccent : Ink.secondary)
                    .frame(width: 13, height: 13)
                    .padding(.horizontal, 2.5)
            }
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

extension ToggleStyle where Self == ScopeToggleStyle {
    static var scope: ScopeToggleStyle { ScopeToggleStyle() }
}

/// The trailing half of a settings row that opens a menu: the current value and a chevron, on a quiet fill.
///
/// The *popup* is an `NSMenu` and stays the system's — it is a window the OS draws, and it is where macOS
/// users expect the system menu. What was native and did not need to be is the closed state: AppKit's pop-up
/// button draws a bezel and its own double chevron, which is the single most recognisable System Settings
/// control after the grouped box.
struct ScopeMenuLabel: View {
    var text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            Text(text)
                .font(.scopeBody)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surface.stroke, lineWidth: 1)
        }
    }
}

/// A stepper drawn as two buttons, in place of AppKit's little stacked arrows.
struct ScopeStepper: View {
    var value: Int
    var range: ClosedRange<Int>
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("minus", enabled: value > range.lowerBound) { onChange(value - 1) }
            button("plus", enabled: value < range.upperBound) { onChange(value + 1) }
        }
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.scopeSecondary)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }
}

/// Our spinner: AppKit's `ProgressView` is sized by `.controlSize`, which a custom one cannot answer, so this
/// takes the size as an argument and every call site states it.
struct ScopeSpinner: View {
    var size: CGFloat = 12
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Ink.tertiary, style: StrokeStyle(lineWidth: max(1, size / 8), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel("Working")
    }
}
