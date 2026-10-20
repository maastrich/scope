import SwiftUI
import ScopeCore
import ScopeTasks

/// The Inbox sheet (⇧⌘I, or the sidebar's Inbox button): what needs the owner, in every scope, grouped by scope
/// with the most recent news first. Each item acts in place — reply, open, mark read, archive, open the pull request,
/// hand the failing checks to the thread — and the keyboard walks it the way Linear's inbox does.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        let groups = model.inboxGroups
        let order = groups.flatMap(\.items)
        VStack(spacing: 0) {
            header(count: order.count)
            Divider()
            if order.isEmpty {
                empty
            } else {
                list(groups)
            }
            Divider()
            InboxKeyHints(item: order.first { $0.id == model.inbox.selected })
        }
        .frame(width: 720, height: 620)
        .background(Surface.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handle(press, order: order) }
        .onAppear {
            if model.inbox.selected == nil || !order.contains(where: { $0.id == model.inbox.selected }) {
                model.inbox.selected = order.first?.id
            }
            listFocused = true
        }
        .onChange(of: model.inbox.replyingTo) { _, now in
            if now == nil { listFocused = true }
        }
        .onChange(of: order.map(\.id)) { old, new in
            keepSelection(old: old, new: new)
        }
        .onDisappear { model.inbox.replyingTo = nil }
        .usageSurface("inbox", label: "Inbox")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("Inbox")
                .font(.system(size: 14, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Ink.secondary)
            }
            Text("every scope")
                .font(.system(size: 12))
                .foregroundStyle(Ink.tertiary)
            Spacer(minLength: 8)
            Button("Close") { model.globalSheet = nil }
                .buttonStyle(.scopeSecondary)
                .usageID("close", label: "Close")
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
        .background(Surface.panel)
    }

    private func list(_ groups: [Inbox.Group]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                InboxRow(item: item, selected: model.inbox.selected == item.id)
                                    .id(item.id)
                            }
                        } header: {
                            InboxScopeHeader(scopeID: group.scopeID, count: group.items.count)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: model.inbox.selected) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text("Nothing needs you")
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
            Text("Questions, finished turns, failures and pull requests ready to merge land here.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, order: [Inbox.Item]) -> KeyPress.Result {
        // The reply field has the keyboard while it is open; a key that reaches here then is not ours.
        guard model.inbox.replyingTo == nil, press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .ignored
        }
        if press.key == .escape {
            model.globalSheet = nil
            return .handled
        }
        if press.key == .downArrow { return move(1, order) }
        if press.key == .upArrow { return move(-1, order) }
        guard let item = order.first(where: { $0.id == model.inbox.selected }) else {
            return ["j", "k"].contains(press.characters) ? move(1, order) : .ignored
        }
        if press.key == .return {
            model.openInboxItem(item)
            return .handled
        }
        switch press.characters {
        case "j": return move(1, order)
        case "k": return move(-1, order)
        case "r":
            guard item.kind.isThreadItem, !model.inboxItemShowsADialog(item) else { return .ignored }
            model.inbox.replyingTo = item.id
        case "e":
            model.markInboxItemRead(item)
        case "a":
            guard item.kind == .readyToMerge || item.kind == .checksFailing else { return .ignored }
            model.archiveInboxTask(item)
        case "o":
            guard item.pullRequestURL != nil else { return .ignored }
            model.openInboxPullRequest(item)
        case "s":
            guard item.kind == .checksFailing else { return .ignored }
            model.sendInboxCheckFailures(item)
        case "v":
            guard item.kind == .scheduleRan, item.threadID != nil else { return .ignored }
            model.readInboxReply(item)
        default:
            return .ignored
        }
        return .handled
    }

    private func move(_ step: Int, _ order: [Inbox.Item]) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = order.firstIndex { $0.id == model.inbox.selected }.map { $0 + step } ?? 0
        model.inbox.selected = order[min(max(index, 0), order.count - 1)].id
        return .handled
    }

    /// An item that leaves (marked read, answered, archived) hands the selection to the one that took its place, so
    /// e e e clears the list from the top without touching j.
    private func keepSelection(old: [String], new: [String]) {
        guard let selected = model.inbox.selected, !new.contains(selected) else { return }
        guard let index = old.firstIndex(of: selected) else {
            model.inbox.selected = new.first
            return
        }
        let following = old[(index + 1)...].first { new.contains($0) }
        let preceding = old[..<index].last { new.contains($0) }
        model.inbox.selected = following ?? preceding
    }
}

/// A scope's heading in the list: its tile, its name, how many items it has.
struct InboxScopeHeader: View {
    @Environment(AppModel.self) private var model
    let scopeID: ScopeID
    let count: Int
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            if let scope = model.scope(scopeID) {
                ScopeTile(scope: scope, size: compact ? 14 : 16)
                Text(scope.name)
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            } else {
                Text("Unknown scope")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
            Spacer()
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.top, compact ? 8 : 12)
        .padding(.bottom, 4)
        .background(compact ? Color.clear : Surface.surface)
    }
}

/// The keys of the selected item, at the foot of the sheet: only the ones that do something to it.
struct InboxKeyHints: View {
    @Environment(AppModel.self) private var model
    let item: Inbox.Item?

    var body: some View {
        HStack(spacing: 14) {
            hint("j k", "move")
            if let item {
                hint("↩", item.kind == .archivedOnMerge ? "restore" : "open")
                if item.kind.isThreadItem, !model.inboxItemShowsADialog(item) { hint("r", "reply") }
                hint("e", item.kind.isThreadItem ? "mark read" : "done")
                if item.kind == .readyToMerge || item.kind == .checksFailing { hint("a", "archive task") }
                if item.pullRequestURL != nil { hint("o", "open PR") }
                if item.kind == .checksFailing { hint("s", "send checks to thread") }
                if item.kind == .scheduleRan, item.threadID != nil { hint("v", "read reply") }
            }
            Spacer()
            hint("esc", "close")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Surface.panel)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary)
        }
    }
}
