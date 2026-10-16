import SwiftUI

/// A message to a thread, typed outside its terminal: ↩ sends, ⇧↩ (or ⌥↩) starts a new line, Esc gives up. The
/// palette's *Ask Orchestrator…* and the sidebar's inline reply both use it, so the two keys mean the same in both.
struct MessageComposer: View {
    @Binding var text: String
    let placeholder: String
    var font: Font = .scopeBody
    /// Fixed: a `TextEditor` has no height of its own to grow from; a longer message scrolls.
    var height: CGFloat = 60
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .frame(height: height)
                .focused($focused)
                .accessibilityLabel(placeholder)
                .onKeyPress(.return, phases: .down) { press in
                    // ⇧↩ and ⌥↩ fall through to the text view, which inserts the line break.
                    guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
                    onSend()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
        }
        .task {
            // The terminal (or the sidebar list) holds the keyboard: take it once the editor is in the window.
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }
}
