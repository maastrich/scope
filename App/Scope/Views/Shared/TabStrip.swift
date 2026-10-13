import SwiftUI

/// A row of flat text tabs, in place of `Picker` + `.pickerStyle(.segmented)`.
///
/// The segmented control is the most system-looking thing macOS hands you: a bezelled group with a saturated
/// fill on the selected segment, sized and coloured by the OS. It says "System Settings" long before it says
/// anything about the app around it. This says the same thing with a label, a quiet fill and nothing else —
/// which is what every app whose chrome is its own does, and it lets the accent stay rare instead of sitting
/// permanently on whichever tab happens to be open.
///
/// Still a set of buttons, so Tab reaches them and VoiceOver announces the selected one; the keyboard
/// shortcuts that move these tabs never went through the Picker anyway (`AppModel.showInspector(_:)`).
struct TabStrip<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]
    /// A tab that has nothing to show right now is drawn dimmed and cannot be picked, with `disabledHelp` as its
    /// tooltip — rather than a tab that takes the click and does nothing.
    var isEnabled: (Value) -> Bool = { _ in true }
    var disabledHelp = ""

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                Tab(title: item.title,
                    isSelected: selection == item.value) { selection = item.value }
                    .disabled(!isEnabled(item.value))
                    .help(isEnabled(item.value) ? "" : disabledHelp)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct Tab: View {
        let title: String
        let isSelected: Bool
        let select: () -> Void
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: select) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? Ink.primary : Ink.tertiary)
                    .opacity(isEnabled ? 1 : 0.5)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }

        private var fill: Color {
            if isSelected { return Fill.quiet }
            return hovering && isEnabled ? Fill.hover : .clear
        }
    }
}
