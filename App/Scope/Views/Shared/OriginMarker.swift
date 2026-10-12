import SwiftUI

/// The mark on a thread an agent opened: a turned arrow, "came from another thread", in `Origin.agent`.
///
/// A glyph and not a dot, because every filled shape in a row already belongs to the state legend — a
/// lavender circle beside the state dot would read as a seventh state. It sits with the title, away from the
/// trailing column the dot owns.
struct OriginMarker: View {
    @Environment(\.isOnAccent) private var isOnAccent

    var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.scopeMicro)
            .foregroundStyle(isOnAccent ? Ink.onAccent : Origin.agent)
            .accessibilityLabel("Opened by an agent")
    }
}
