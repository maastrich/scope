import AppKit
import SwiftUI

/// A small icon button that puts a string on the pasteboard and shows a checkmark for a moment, so the user
/// knows it happened. `text` is asked for at click time (it may depend on the modifier keys held).
struct CopyButton: View {
    let label: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text())
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? AnyShapeStyle(ThreadStateStyle.done) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.iconTight)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}
