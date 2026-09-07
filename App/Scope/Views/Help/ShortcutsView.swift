import SwiftUI

/// One row of the shortcuts sheet.
struct ShortcutEntry: Identifiable {
    let keys: String
    let title: String
    var note: String? = nil

    var id: String { "\(keys) \(title)" }
}

/// One group of shortcuts (mirrors a menu).
struct ShortcutGroup: Identifiable {
    let title: String
    let entries: [ShortcutEntry]

    var id: String { title }
}

/// The single source of truth for the shortcuts listed in Help ▸ Keyboard Shortcuts…; menus, tooltips and
/// palette hints use the same key strings.
enum ShortcutCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Scope", entries: [
            ShortcutEntry(keys: "⌘O", title: "Add Scope…"),
            ShortcutEntry(keys: "⌘R", title: "Refresh Scope"),
            ShortcutEntry(keys: "⌘,", title: "Settings…"),
            ShortcutEntry(keys: "⇧⌘W", title: "Close Window"),
        ]),
        ShortcutGroup(title: "Threads", entries: [
            ShortcutEntry(keys: "⌘T", title: "New Thread", note: "in the current task when one is selected"),
            ShortcutEntry(keys: "⇧⌘T", title: "New Task…", note: "Undo Close Thread while a close can be undone"),
            ShortcutEntry(keys: "⌘W", title: "Close Thread"),
            ShortcutEntry(keys: "⌥⌘R", title: "Relaunch"),
            ShortcutEntry(keys: "⌘.", title: "Stop"),
            ShortcutEntry(keys: "⌘1 … ⌘9", title: "Thread 1 … 9"),
            ShortcutEntry(keys: "⇧⌘]", title: "Next Thread"),
            ShortcutEntry(keys: "⇧⌘[", title: "Previous Thread"),
            ShortcutEntry(keys: "⌥⌘K", title: "Clear Scrollback"),
        ]),
        ShortcutGroup(title: "Find", entries: [
            ShortcutEntry(keys: "⌘F", title: "Find in Terminal", note: "the terminal pane must have focus"),
            ShortcutEntry(keys: "⌘G", title: "Find Next"),
            ShortcutEntry(keys: "⇧⌘G", title: "Find Previous"),
            ShortcutEntry(keys: "⌥⌘E", title: "Use Selection for Find"),
            ShortcutEntry(keys: "⌘K", title: "Command Palette"),
            ShortcutEntry(keys: "⌘P", title: "Go to File…", note: "also ⇧⌘O"),
            ShortcutEntry(keys: "⌥⌘F", title: "Filter Sidebar", note: "Esc clears"),
            ShortcutEntry(keys: "↑ ↓ ↩", title: "Navigate and open", note: "palette and Base search results"),
            ShortcutEntry(keys: "⌥↩", title: "Copy path", note: "palette rows with a path"),
        ]),
        ShortcutGroup(title: "Go", entries: [
            ShortcutEntry(keys: "⌘E", title: "Open in Editor"),
            ShortcutEntry(keys: "⇧⌘E", title: "Open Task in Editor"),
            ShortcutEntry(keys: "⌘D", title: "Delta"),
            ShortcutEntry(keys: "⇧⌘B", title: "Base"),
            ShortcutEntry(keys: "⇧⌘P", title: "Pull Requests"),
            ShortcutEntry(keys: "⌥⌘I", title: "Toggle Inspector"),
            ShortcutEntry(keys: "⌃⌘S", title: "Toggle Sidebar"),
        ]),
        ShortcutGroup(title: "Delta panel", entries: [
            ShortcutEntry(keys: "j / k", title: "Next / previous file", note: "the Delta panel must have focus"),
            ShortcutEntry(keys: "] / [", title: "Next / previous hunk"),
        ]),
        ShortcutGroup(title: "Help", entries: [
            ShortcutEntry(keys: "⌘/", title: "Keyboard Shortcuts…"),
        ]),
    ]
}

/// Help ▸ Keyboard Shortcuts…: every shortcut of the app, grouped like the menus.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ShortcutCatalog.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                        ForEach(group.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.keys)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .frame(width: 92, alignment: .trailing)
                                    .foregroundStyle(.primary)
                                Text(entry.title)
                                    .font(.system(size: 12.5))
                                if let note = entry.note {
                                    Text(note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
