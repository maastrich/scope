import SwiftUI
import ScopeCore

/// Toasts for the closes and archives that can be taken back, newest at the bottom, under the exit toasts. Each
/// one: `“Title” closed — Reopen` or `“Name” archived — Undo`, and a dismiss that keeps ⌘Z working. Hovering holds
/// the 10 s countdown.
struct UndoToastStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.undoNotices) { notice in
                UndoToast(notice: notice)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.undoNotices.map(\.id))
        .usageArea("undo-toast")
    }
}

private struct UndoToast: View {
    @Environment(AppModel.self) private var model
    let notice: UndoNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 14))
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(notice.buttonTitle) {
                model.undo(noticeID: notice.id)
            }
            .buttonStyle(.scopeSecondary)
            .usageID(notice.usageElement, label: "\(notice.buttonTitle) (undo toast)")
            Button {
                model.dismissUndoNotice(notice.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss (⌘Z still works for a few minutes)")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        .frame(maxWidth: 560)
        .onHover { model.holdUndoNotice(notice.id, $0) }
        .accessibilityElement(children: .contain)
    }
}
