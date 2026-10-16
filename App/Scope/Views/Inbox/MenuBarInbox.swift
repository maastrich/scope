import AppKit
import SwiftUI
import ScopeTasks

/// The menu bar extra (spec §7, optional): the Inbox, compact — every item with Reply and Open, then the way into the
/// full sheet and the window. Replying from here leaves the window where it was.
struct MenuBarInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = model.inboxGroups
        VStack(spacing: 0) {
            if groups.isEmpty {
                Text("Nothing needs you")
                    .font(.scopeBody)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            InboxScopeHeader(scopeID: group.scopeID, count: group.items.count, compact: true)
                            ForEach(group.items) { item in
                                InboxRow(item: item, compact: true) { bringUp() }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open Inbox") {
                    bringUp()
                    model.showInbox()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .usageID("open-inbox", label: "Open Inbox")
                Button("Ask Orchestrator…") {
                    dismiss()
                    model.showQuickPanel(tab: .ask)
                }
                .usageID("ask-orchestrator", label: "Ask Orchestrator…")
                Spacer()
                Button("Open Scope") { bringUp() }
                    .usageID("open-scope", label: "Open Scope")
            }
            .buttonStyle(.scopeGhost)
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .frame(width: 380)
        .background(Surface.surface)
        .onDisappear { model.inbox.replyingTo = nil }
        .usageSurface("menu-bar-inbox", label: "Menu bar inbox")
    }

    private func bringUp() {
        dismiss()
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) {
            openWindow(id: "main")
        }
    }
}
