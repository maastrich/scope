import SwiftUI
import ScopeAdapters
import ScopeCore

/// The sidebar's reply field, under the row of the thread it answers (⌥↩, or *Reply…* in the row's menu): the end of
/// what the agent last said, then the field. ↩ sends, ⇧↩ starts a new line, Esc closes. The selection and the terminal
/// on screen stay as they were, so a waiting thread is answered without leaving the one being worked in.
///
/// A row of its own rather than part of `ThreadRow`: it takes no selection and carries no tag, and the thread row's
/// layout stays the thread row's. Draws nothing unless its thread is the one being replied to.
struct InlineReplySlot: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadID
    var depth = 0

    var body: some View {
        if model.messageUI.replyingTo == thread, let session = model.session(thread) {
            InlineReplyRow(session: session, depth: depth)
                .selectionDisabled()
                .listRowSeparator(.hidden)
        }
    }
}

private struct InlineReplyRow: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession
    let depth: Int
    @State private var draft = ""

    /// Read once: `activity` is not observed (it moves on every tool call), and a reply arriving while the field is
    /// open must not shift the text being typed under it.
    @State private var excerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let excerpt {
                Text(excerpt)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            MessageComposer(text: $draft, placeholder: "Reply to \(model.displayTitle(for: session))…",
                            font: .system(size: 12), height: 54) {
                guard model.sendMessage(draft, to: session.id, toast: false) else { return }
                model.endReply()
            } onCancel: {
                model.endReply()
            }
            .scopeTextBox(focused: true, inset: 2)
            Text("↩ send · ⇧↩ new line · esc")
                .font(.system(size: 10))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent + SidebarMetrics.glyphSlot + SidebarMetrics.spacing)
        .padding(.vertical, 4)
        .onAppear {
            excerpt = UserMessage.replyExcerpt(session.activity.lastReply ?? session.lastReply,
                                               lastPromptAt: session.lastPromptAt)
        }
    }
}
