import SwiftUI

/// The sidebar's way into the Inbox, first of the global views: the tray, and the number of items in every scope. The
/// count takes the accent while one of them is a thread waiting for an answer, the one kind that blocks an agent.
struct InboxButton: View {
    @Environment(AppModel.self) private var model
    var showsTitle = true

    var body: some View {
        let items = model.inboxItems
        let blocking = items.contains { $0.kind == .question || $0.kind == .permission }
        Button {
            model.showInbox()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: items.isEmpty ? "tray" : "tray.full")
                if showsTitle {
                    Text("Inbox").lineLimit(1)
                }
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(blocking ? Ink.onAccent : Ink.primary)
                        .padding(.horizontal, 4)
                        .frame(height: 15)
                        .background(blocking ? AnyShapeStyle(ThreadStateStyle.waiting) : AnyShapeStyle(Fill.quiet),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(maxWidth: showsTitle ? .infinity : nil)
            .padding(.horizontal, showsTitle ? 0 : 4)
        }
        .help("What needs you, in every scope (⇧⌘I)")
        .accessibilityLabel(items.isEmpty ? "Inbox" : "Inbox, \(items.count) items")
        .usageID("inbox", label: "Inbox")
    }
}
