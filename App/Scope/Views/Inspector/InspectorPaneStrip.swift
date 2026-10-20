import SwiftUI
import ScopeCore
import ScopeTasks

/// The strip at the right of the inspector band: the column's two pages, Overview and Details (`InspectorPage`), then
/// the panes — Changes, Shell, Browser, Pull requests, Files — and `⋮` with the Cards menu. Overview turns to its page and
/// closes the pane; Details (⇧⌘D) turns to the other page and back. A pane button opens its card, on whichever page
/// it is, *and* its pane when it has one (the diff for Changes, the base file for Files).
///
/// Badges say what waits: the changed files on Changes, the failing checks on Pull requests. Details carries a quiet
/// dot, no count, when a card went down to it while it was not on show. Without a task there is one page and the
/// strip is the base checkout's: Overview, Files, Search, `⋮`.
struct InspectorPaneStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let task = model.currentTask
        let viewer = model.shownViewer
        HStack(spacing: 1) {
            PaneButton(systemImage: "list.bullet.rectangle", title: "Overview",
                       selected: viewer == nil && (task == nil || model.inspector.page == .overview)) {
                Usage.click("inspector.panes.overview", label: "Overview pane")
                model.showInspectorPage(.overview)
                model.inspector.closeViewer()
            }
            .help(task == nil ? "Overview — the cards alone, the pane closed"
                              : "Overview — what is happening: the cards with something to say, the pane closed")
            if let task {
                PaneButton(systemImage: "info.circle", title: "Details", dot: model.inspector.detailsHasNews,
                           selected: model.inspector.page == .details) {
                    Usage.click("inspector.panes.details", label: "Details page")
                    model.toggleInspectorDetails()
                }
                .keyHints { CommandKeyHints.shared.keys(for: "command.details").map { [$0] } ?? [] }
                .help(model.inspector.detailsHasNews
                      ? "Details (⇧⌘D) — a card went quiet and moved here"
                      : "Details (⇧⌘D) — environment, context, the base checkout, and the cards with nothing to say yet")
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
                PaneButton(systemImage: "globe", title: "Browser", selected: viewer == .browser) {
                    Usage.click("inspector.panes.browser", label: "Browser pane")
                    model.toggleBrowser()
                }
                .help("Browser (⌃⇧B) — the task's dev servers in the reading column; again hides it")
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
    /// A quiet mark that something changed behind the button, where a count would shout.
    var dot = false
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
                    } else if dot {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 1, y: 1)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(badge.map { "\($0)" } ?? (dot ? "updated" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `⋮`: where each card goes, one submenu each — by itself (Overview while it has something to say for an event card,
/// Details for the others), always on Overview however quiet, or nowhere — and *Reset to defaults*. Kept per scope
/// with the open cards (`InspectorSections.pinned`, `.hidden`).
private struct CardsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScopeMenu {
            Section("Overview when they have something") {
                ForEach(InspectorSection.eventCards, id: \.self) { section in
                    choice(section, automatic: "When it has something")
                }
            }
            Section("Details") {
                ForEach(InspectorSection.allCases.filter { !$0.isEventCard }, id: \.self) { section in
                    choice(section, automatic: "In Details")
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
        .help("Cards — where each card goes: by itself, always on Overview, or hidden")
        .accessibilityLabel("Cards")
        .usageID("inspector.panes.cards", label: "Cards menu")
    }
}

extension CardsMenu {
    fileprivate func choice(_ section: InspectorSection, automatic: String) -> some View {
        Picker(section.title, selection: Binding<AppModel.CardPlacementChoice>(
            get: {
                if !model.isSectionVisible(section) { return .hidden }
                return model.inspector.sections.isPinned(section) ? .pinned : .automatic
            },
            set: { model.setCard(section, $0) })) {
            Text(automatic).tag(AppModel.CardPlacementChoice.automatic)
            Text("Always in Overview").tag(AppModel.CardPlacementChoice.pinned)
            Text("Hidden").tag(AppModel.CardPlacementChoice.hidden)
        }
    }
}
