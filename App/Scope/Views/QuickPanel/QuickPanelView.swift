import SwiftUI
import ScopeCore
import ScopeTasks

/// The quick panel (spec §7): the app's chrome in a small floating card. Two tabs — *Ask*, a message to a scope's
/// orchestrator, the scope picked from a row of tiles or ⌃1…9; *Inbox*, what needs the owner with Reply and Open in
/// place, walked with j/k. ↩ sends or opens, Esc closes (the window takes it, see `QuickPanelController`).
struct QuickPanelView: View {
    static let width: CGFloat = 560

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var state = model.quickPanel
        VStack(spacing: 0) {
            header(tab: $state.tab)
            Divider()
            switch state.tab {
            case .ask: QuickPanelAsk()
            case .inbox: QuickPanelInbox()
            }
        }
        .frame(width: Self.width)
        .background(Surface.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Surface.stroke))
        .usageSurface("quick-panel", label: "Quick panel")
    }

    private func header(tab: Binding<QuickPanel.Tab>) -> some View {
        HStack(spacing: 10) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(Ink.tertiary)
            TabStrip(selection: tab, items: [(QuickPanel.Tab.ask, "Ask"), (QuickPanel.Tab.inbox, "Inbox")])
                .usageID("tabs", label: "Ask / Inbox")
            if model.inboxCount > 0 {
                Text("\(model.inboxCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.waitingThreads.isEmpty ? Ink.tertiary : ThreadStateStyle.waiting)
            }
            Spacer(minLength: 8)
            Text("esc")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
        .background(Surface.panel, in: UnevenRoundedRectangle(topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg, style: .continuous))
    }
}

// MARK: - Ask

/// The scope row, then the field. The current scope is addressed unless a tile or ⌃digit says otherwise.
private struct QuickPanelAsk: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var state = model.quickPanel
        VStack(alignment: .leading, spacing: 10) {
            if model.scopes.count > 1 {
                scopeRow
            }
            if let notice = state.sentNotice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ThreadStateStyle.done)
                    Text(notice)
                        .font(.scopeBody)
                        .foregroundStyle(Ink.secondary)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else if let orchestrator = model.quickPanelOrchestrator {
                target(orchestrator)
                MessageComposer(text: $state.draft, placeholder: "Ask the \(model.messageTargetName(orchestrator.id))…",
                                font: .system(size: 15), height: 96) {
                    model.sendFromQuickPanel()
                } onCancel: {
                    model.hideQuickPanel()
                }
                .scopeTextBox(focused: true, inset: 2)
                .usageID("ask-field", label: "Ask field")
                Text("↩ send · ⇧↩ new line" + (model.scopes.count > 1 ? " · ⌃1…9 scope" : ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.tertiary)
            } else {
                VStack(spacing: 6) {
                    Text(model.scopes.isEmpty ? "No scope declared yet" : "\(model.quickPanelScope?.name ?? "This scope") has no orchestrator")
                        .font(.scopeBody)
                        .foregroundStyle(Ink.secondary)
                    Text(model.scopes.isEmpty ? "Declare a folder in Scope first." : "Install an agent driver; the orchestrator starts with the scope.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .animation(.easeOut(duration: 0.15), value: state.sentNotice)
    }

    private var scopeRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.scopes.prefix(9).enumerated()), id: \.element.id) { index, scope in
                let addressed = model.quickPanelScope?.id == scope.id
                Button {
                    model.quickPanel.chosenScope = scope.id
                } label: {
                    HStack(spacing: 6) {
                        ScopeTile(scope: scope, activity: addressed ? nil : model.activity(of: scope), size: 16)
                        if addressed {
                            Text(scope.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(addressed ? Fill.quiet : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(scope.name) (⌃\(index + 1))")
                .accessibilityLabel(scope.name)
                .accessibilityAddTraits(addressed ? .isSelected : [])
                .usageID("scope-tile", label: "Scope tile")
            }
            Spacer(minLength: 0)
        }
    }

    private func target(_ orchestrator: ThreadSession) -> some View {
        HStack(spacing: 6) {
            StateDot(state: orchestrator.displayState)
                .frame(width: 12)
            Text("To the \(model.messageTargetName(orchestrator.id))")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !orchestrator.isAlive {
                Text("· starts it")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }
}

// MARK: - Inbox

/// The Inbox, compact and flat: the questions on top, then the rest, each row with Reply and Open as in the menu
/// bar extra, and the sheet's keys where they apply here.
private struct QuickPanelInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var listFocused: Bool

    var body: some View {
        let order = model.quickPanelInboxItems
        VStack(spacing: 0) {
            if order.isEmpty {
                empty
            } else {
                list(order)
            }
            Divider()
            hints(order.first { $0.id == model.quickPanel.selected })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handle(press, order: order) }
        .onAppear { listFocused = true }
        .onChange(of: model.inbox.replyingTo) { _, now in
            if now == nil { listFocused = true }
        }
        .onChange(of: order.map(\.id)) { old, new in keepSelection(old: old, new: new) }
    }

    private func list(_ order: [Inbox.Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(order) { item in
                        HStack(alignment: .top, spacing: 0) {
                            if let scope = model.scope(item.scopeID) {
                                ScopeTile(scope: scope, size: 14)
                                    .padding(.top, 7)
                                    .padding(.leading, 8)
                                    .help(scope.name)
                            }
                            InboxRow(item: item, selected: model.quickPanel.selected == item.id, compact: true) {
                                model.hideQuickPanel()
                                NSApp.activate()
                            }
                        }
                        .id(item.id)
                        // Simultaneous: the row's own tap selects it in the sheet's state, this one in the panel's.
                        .simultaneousGesture(TapGesture().onEnded { model.quickPanel.selected = item.id })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.quickPanel.selected) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text("Nothing needs you")
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    private func hints(_ item: Inbox.Item?) -> some View {
        HStack(spacing: 14) {
            hint("j k", "move")
            if let item {
                hint("↩", item.kind == .archivedOnMerge ? "restore" : "open")
                if item.kind.isThreadItem { hint("r", "reply") }
                hint("e", item.kind.isThreadItem ? "mark read" : "done")
            }
            Spacer()
            hint("⇧⌘I", "full inbox")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Surface.panel, in: UnevenRoundedRectangle(bottomLeadingRadius: Radius.lg, bottomTrailingRadius: Radius.lg, style: .continuous))
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

    // MARK: Keyboard

    private func handle(_ press: KeyPress, order: [Inbox.Item]) -> KeyPress.Result {
        guard model.inbox.replyingTo == nil else { return .ignored }
        // ⇧⌘I: the full sheet, in the window.
        if press.modifiers.contains(.command) {
            guard press.characters.lowercased() == "i" else { return .ignored }
            model.hideQuickPanel()
            NSApp.activate()
            model.showInbox()
            return .handled
        }
        guard press.modifiers.isDisjoint(with: [.control, .option]) else { return .ignored }
        if press.key == .downArrow { return move(1, order) }
        if press.key == .upArrow { return move(-1, order) }
        guard let item = order.first(where: { $0.id == model.quickPanel.selected }) else {
            return ["j", "k"].contains(press.characters) ? move(1, order) : .ignored
        }
        if press.key == .return {
            model.openFromQuickPanel(item)
            return .handled
        }
        switch press.characters {
        case "j": return move(1, order)
        case "k": return move(-1, order)
        case "r":
            guard item.kind.isThreadItem else { return .ignored }
            model.inbox.replyingTo = item.id
        case "e":
            model.markInboxItemRead(item)
        default:
            return .ignored
        }
        return .handled
    }

    private func move(_ step: Int, _ order: [Inbox.Item]) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = order.firstIndex { $0.id == model.quickPanel.selected }.map { $0 + step } ?? 0
        model.quickPanel.selected = order[min(max(index, 0), order.count - 1)].id
        return .handled
    }

    private func keepSelection(old: [String], new: [String]) {
        // The panel may open on an empty list: the first item to arrive is the one the keys act on.
        guard let selected = model.quickPanel.selected else {
            model.quickPanel.selected = new.first
            return
        }
        guard !new.contains(selected) else { return }
        guard let index = old.firstIndex(of: selected) else {
            model.quickPanel.selected = new.first
            return
        }
        model.quickPanel.selected = old[(index + 1)...].first { new.contains($0) } ?? old[..<index].last { new.contains($0) }
    }
}
