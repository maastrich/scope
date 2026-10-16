import SwiftUI
import ScopeCore

/// "Sent to acme orchestrator", for the few seconds after a message left the palette: the thread it went to is not
/// on screen, so this is the only sign it went. *Show* goes there.
struct SentToast: View {
    @Environment(AppModel.self) private var model
    let notice: MessageUIState.SentNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane")
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Show") {
                model.showMessageTarget(notice.thread)
            }
            .buttonStyle(.scopeSecondary)
            Button {
                model.messageUI.dismissSent()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
    }
}
