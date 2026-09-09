import SwiftUI

/// A borderless icon button that answers the pointer: a soft rounded wash on hover, a firmer one while
/// pressed, nothing at rest.
///
/// `.buttonStyle(.plain)` strips a button of every native affordance, which is right for the look and wrong
/// for the feel — the control ends up indistinguishable from static text until you click it and something
/// happens. On macOS the cue for "this does something" is the hover wash, not a hand cursor: the pointing
/// hand means *link* here, and using it for buttons is a web habit that reads as foreign (`.pointerStyle(.link)`
/// is for the few controls that really do open a link).
struct IconButtonStyle: ButtonStyle {
    /// Padding around the label, which is what the wash covers.
    var padding: CGFloat = 4
    var radius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, padding: padding, radius: radius)
    }

    /// A nested view because a `ButtonStyle` cannot hold `@State`, and hover is state. Not called `Body`:
    /// that name collides with the protocol's own associated type.
    private struct HoverLabel: View {
        let configuration: Configuration
        let padding: CGFloat
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(padding)
                .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
                // A disabled button keeps its layout but stops answering: no wash, and the hover state is
                // dropped so it does not come back lit when it is enabled again.
                .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            return hovering ? Color.primary.opacity(0.075) : .clear
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// `.buttonStyle(.icon)` — see ``IconButtonStyle``.
    static var icon: IconButtonStyle { IconButtonStyle() }

    /// A tighter wash, for an icon that sits inside a 28 pt row and must not grow it.
    static var iconTight: IconButtonStyle { IconButtonStyle(padding: 3, radius: 4) }
}
