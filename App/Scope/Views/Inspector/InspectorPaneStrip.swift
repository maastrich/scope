import SwiftUI
import ScopeCore
import ScopeTasks

/// The strip of panes at the right of the inspector band: Overview, Changes, Shell, Pull requests, Files, and `⋮` with the
/// Cards menu. A click opens the card *and* its pane when it has one (the diff for Changes, the base file for
/// Files); Overview closes the pane and leaves the column of cards alone. It is not a tab bar: every card stays in
/// the column whatever is lit here, and `⌘D` / `⇧⌘B` keep working.
///
/// Badges say what waits: the changed files on Changes, the failing checks on Pull requests. Without a task the
/// strip is the base checkout's: Overview, Files, Search, `⋮`.
struct InspectorPaneStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let task = model.currentTask
        let viewer = model.shownViewer
        HStack(spacing: 1) {
            PaneButton(systemImage: "list.bullet.rectangle", title: "Overview", selected: viewer == nil) {
                Usage.click("inspector.panes.overview", label: "Overview pane")
                model.inspector.closeViewer()
            }
            .help("Overview — the cards alone, the pane closed")
            if let task {
                PaneButton(systemImage: "plus.forwardslash.minus", title: "Changes", badge: changedFiles(task),
                           badgeColor: Ink.secondary, selected: viewer == .diff) {
                    Usage.click("inspector.panes.changes", label: "Changes pane")
                    model.revealSection(.delta)
                    if model.delta.selectedFile == nil { model.showDiff(model.delta.orderedFiles.first) } else { model.inspector.show(.diff) }
                }
                .help("Changes (⌘D) — the card and the diff of the selected file")
                PaneButton(systemImage: "terminal", title: "Shell", selected: viewer == .shell) {
                    Usage.click("inspector.panes.shell", label: "Shell pane")
                    model.toggleTaskShell()
                }
                .help("Shell (⌃`) — a shell of the task in the reading column; again hides it")
                PaneButton(systemImage: "arrow.triangle.pull", title: "Pull requests", badge: failingChecks(task),
                           badgeColor: PullRequestStyle.failing, selected: false) {
                    Usage.click("inspector.panes.pull-requests", label: "Pull requests pane")
                    model.revealSection(.pullRequest)
                }
                .help("Pull requests — the card; the badge counts failing checks")
            }
            PaneButton(systemImage: "folder", title: "Files", selected: viewer == .file) {
                Usage.click("inspector.panes.files", label: "Files pane")
                model.revealSection(.files)
                if model.base.content != nil { model.inspector.show(.file) }
            }
            .help("Files — the base checkout's tree, and the file open from it")
            if task == nil {
                PaneButton(systemImage: "magnifyingglass", title: "Search", selected: false) {
                    Usage.click("inspector.panes.search", label: "Search pane")
                    model.revealSection(.search)
                }
                .help("Search across the base checkout")
            }
            CardsMenu()
        }
        .padding(2)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panes")
    }

    private func changedFiles(_ task: TaskState) -> Int? {
        let delta = model.delta
        let count: Int
        if delta.taskID == task.id, delta.hasLoaded, delta.mode != .baseVsOrigin {
            count = delta.summary.files
        } else {
            count = task.activeRepos.compactMap { task.summary(for: $0) }.reduce(0) { $0 + $1.files }
        }
        return count > 0 ? count : nil
    }

    private func failingChecks(_ task: TaskState) -> Int? {
        let failing = model.pullRequestFacts(for: task).filter { $0.state == .open && $0.checks == .failing }.count
        return failing > 0 ? failing : nil
    }
}

/// One 22 pt button of the strip: a glyph, a count badge at its corner when there is something to count, a lit
/// background while its pane is the one shown.
private struct PaneButton: View {
    let systemImage: String
    let title: String
    var badge: Int? = nil
    var badgeColor: Color = Ink.secondary
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                .frame(width: 24, height: 20)
                .background(selected ? Surface.panel : (hovering ? Fill.hover : .clear),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(Ink.onAccent)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(badgeColor, in: Capsule())
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(badge.map { "\($0)" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `⋮`: which cards the column shows, one check mark each, and *Reset to defaults*. Kept per scope with the open
/// cards (`InspectorSections.hidden`). A card that needs a task can be shown or hidden without one; it stays dimmed.
private struct CardsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScopeMenu {
            Section("Cards") {
                ForEach(InspectorSection.allCases, id: \.self) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { model.isSectionVisible(section) },
                        set: { model.setSection(section, visible: $0) }))
                }
            }
            Divider()
            Button("Reset to defaults") { model.resetSections() }
        } label: { hovering in
            Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 24, height: 20)
                .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .help("Cards — choose which cards the column shows")
        .accessibilityLabel("Cards")
        .usageID("inspector.panes.cards", label: "Cards menu")
    }
}
