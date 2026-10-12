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
            .scopeFieldGround(focused: focused)
    }

    /// The same box around text that grows: a `TextEditor`, a `TextField(axis: .vertical)`. A fixed height
    /// would clip the second line, so this one pads and lets the content decide.
    ///
    /// `inset` is 7 for a text field and 2 for a `TextEditor`, whose text container already insets by 5.
    func scopeTextBox(focused: Bool, inset: CGFloat = 7) -> some View {
        padding(.horizontal, inset)
            .padding(.vertical, 5)
            .scopeFieldGround(focused: focused)
    }

    private func scopeFieldGround(focused: Bool) -> some View {
        background(Surface.field, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
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

/// The closed state of anything that opens a menu: the current value or the action's name, and a chevron.
///
/// The *popup* is an `NSMenu` and stays the system's — it is a window the OS draws, and it is where macOS
/// users expect the system menu. What was native and did not need to be is the closed state: AppKit's pop-up
/// button draws a bezel and its own double chevron, which is the single most recognisable System Settings
/// control after the grouped box.
///
/// `.primary` exists for the one case where the menu *is* the surface's primary action (Send Review, when
/// there are several threads to send it to); everything else is `.secondary`.
struct ScopeMenuLabel: View {
    enum Kind { case primary, secondary }

    var text: String
    var systemImage: String?
    var kind: Kind = .secondary
    var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.scopeCaption)
                    .foregroundStyle(kind == .primary ? Ink.onAccent : Ink.secondary)
            }
            Text(text)
                .font(.scopeBody)
                .foregroundStyle(kind == .primary ? Ink.onAccent : Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.scopeMicro)
                .foregroundStyle(kind == .primary ? Ink.onAccent : Ink.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            if kind == .secondary {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Surface.stroke, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var fill: Color {
        switch kind {
        case .primary: Color.accentColor
        case .secondary: hovering ? Fill.hover : Fill.quiet
        }
    }
}

/// A menu whose trigger is ours. `Menu` draws its label through AppKit unless it is a plain button, and a
/// plain button has no hover — so the hover is tracked out here and handed to the label.
///
/// Every `Menu` that is a visible control goes through this; a `.contextMenu` and a submenu are not controls
/// and stay as they are.
struct ScopeMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    /// Receives whether the pointer is over the trigger.
    var label: (Bool) -> Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: @escaping (Bool) -> Label) {
        self.content = content()
        self.label = label
    }

    var body: some View {
        Menu {
            content
        } label: {
            label(hovering && isEnabled)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Vertical only: a long value — a pull request's title, a branch — has to truncate inside its row,
        // not push the row past the edge of the sheet.
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

extension ScopeMenu where Label == ScopeMenuLabel {
    /// The ordinary case: a name, an optional glyph, a chevron.
    init(_ text: String, systemImage: String? = nil, kind: ScopeMenuLabel.Kind = .secondary,
         @ViewBuilder content: () -> Content) {
        self.init(content: content) { hovering in
            ScopeMenuLabel(text: text, systemImage: systemImage, kind: kind, hovering: hovering)
        }
    }
}

/// A menu behind a lone glyph — the `…` of a row, a send arrow. The wash is `IconButtonStyle`'s, so the
/// glyph that opens a menu and the glyph that acts answer the pointer the same way.
struct ScopeIconMenu<Content: View>: View {
    var systemImage: String
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScopeMenu {
            content
        } label: { hovering in
            Image(systemName: systemImage)
                .font(.scopeCaption.weight(.semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16, height: 16)
                .padding(3)
                .background(hovering ? Fill.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A choice among a few values, in place of `Picker`'s pop-up button. The inline `Picker` inside the menu
/// keeps what the system does well — the checkmark, type-to-select, VoiceOver's "selected" — and the closed
/// state is `ScopeMenuLabel`.
///
/// `title` is the current value's name: a custom label cannot ask the picker which row is selected.
struct ScopePicker<Value: Hashable, Content: View>: View {
    /// What is being chosen, for VoiceOver; the visible label belongs to the row.
    var label: String
    @Binding var selection: Value
    var title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    init(_ label: String, selection: Binding<Value>, title: String, systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        _selection = selection
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScopeMenu(title, systemImage: systemImage) {
            Picker(label, selection: $selection) { content }
                .pickerStyle(.inline)
                .labelsHidden()
        }
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

/// An action that reads as text: "Reveal", "Edit", a file path that jumps to its diff. In place of
/// `.buttonStyle(.link)`, whose system blue spent the accent on something that is not the primary action.
/// Secondary ink at rest, primary ink and a wash under the pointer; it keeps the font of the view it is in.
struct ScopeLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            ScopeLinkLabel(hovering: hovering && isEnabled, pressed: configuration.isPressed) {
                configuration.label
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
        }
    }
}

extension ButtonStyle where Self == ScopeLinkButtonStyle {
    static var scopeLink: ScopeLinkButtonStyle { ScopeLinkButtonStyle() }
}

/// What `ScopeLinkButtonStyle` draws, on its own so a `ScopeMenu` can wear it too. Whoever wears it dims it
/// when disabled — the style, or the menu — so it is not dimmed twice.
struct ScopeLinkLabel<Content: View>: View {
    var hovering: Bool
    var pressed = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(pressed ? Fill.pressed : (hovering ? Fill.hover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
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

/// A spinner with the sentence that says what it is waiting for, stacked — what `ProgressView("Loading…")`
/// drew, for a pane that has nothing else to show yet.
struct ScopeLoading: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            ScopeSpinner(size: 14)
            Text(text)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A determinate bar: a 4 pt track with the done part in secondary ink. Not the accent — progress is a
/// reading, not an action.
struct ScopeProgressBar: View {
    /// 0…1.
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Ink.secondary)
                .frame(width: proxy.size.width * min(1, max(0, fraction)))
        }
        .frame(height: 4)
        .background(Fill.pressed, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

/// A 0…1 slider: a 4 pt track and a round thumb, in place of AppKit's. VoiceOver and the arrow keys get the
/// system slider through `accessibilityRepresentation`, so nothing is lost by drawing it.
struct ScopeSlider: View {
    @Binding var value: Double
    private let thumb: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let span = max(1, proxy.size.width - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(Fill.pressed).frame(height: 4)
                Capsule().fill(Ink.secondary).frame(width: thumb / 2 + span * value, height: 4)
                Circle()
                    .fill(Ink.primary)
                    .frame(width: thumb, height: thumb)
                    .offset(x: span * value)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = min(1, max(0, (drag.location.x - thumb / 2) / span))
            })
        }
        .frame(height: 16)
        .accessibilityRepresentation { Slider(value: $value, in: 0...1) }
    }
}
