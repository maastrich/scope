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
            ForEach(model.tryingTasks) { task in
                MenuBarTryRow(task: task)
                Divider()
            }
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

/// One line per task a base checkout is on (spec §4.5), with Put back: the menu bar says it wherever the window is.
private struct MenuBarTryRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .foregroundStyle(Color("WarningText"))
            VStack(alignment: .leading, spacing: 1) {
                Text("Your checkout is on \(task.name)")
                    .font(.scopeBody)
                    .lineLimit(1)
                if let since = task.record.trying.first?.since {
                    Text("since \(since.formatted(date: .omitted, time: .shortened)) · \(task.branch)")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Put back") {
                Usage.click("menu-bar.try-put-back", label: "Put my checkout back")
                Task {
                    do { _ = try await model.putBack(task) } catch {
                        model.problems.error("Could not put your checkout back from \(task.name)", detail: String(describing: error), scope: task.scopeID)
                    }
                }
            }
            .buttonStyle(.scopeGhost)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
