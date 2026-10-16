import AppKit
import Observation
import ScopeAdapters
import ScopeCore
import ScopeTasks

/// What the quick panel needs beyond `AppModel` (extended, not edited): the tab on screen, the scope the Ask field
/// addresses, the Inbox row the keyboard acts on, and the word that says a message went.
@MainActor
@Observable
final class QuickPanelState {
    static let shared = QuickPanelState()

    var tab: QuickPanel.Tab = .ask
    /// The scope picked in the panel (⌃1…9, a tile); `nil` follows the app's current scope.
    var chosenScope: ScopeID?
    /// The Inbox row the keyboard acts on (`Inbox.Item.id`).
    var selected: String?
    /// *Sent to the acme orchestrator*, shown for a moment before the panel goes.
    var sentNotice: String?
    var draft = ""
}

/// The quick panel (spec §7): a system-wide hotkey opens it over whatever is on screen — an idea for an orchestrator
/// or an answer to a waiting agent without switching to Scope. The chrome is `QuickPanelController`; the decisions
/// (`QuickPanel`) are ScopeKit's; this is where they meet the app's threads and scopes.
extension AppModel {
    var quickPanel: QuickPanelState { .shared }

    /// Starts the system-wide chords, once the model is up.
    func startGlobalHotkeys() {
        GlobalHotkeys.shared.start(model: self, actions: [
            .quickPanel: { [weak self] in self?.toggleQuickPanel() },
            .toggleWindow: { [weak self] in self?.toggleMainWindow() },
        ])
    }

    /// The hotkey: opens the panel on the tab the preference says, or closes it when it is up.
    func toggleQuickPanel() {
        if QuickPanelController.shared.isShown {
            hideQuickPanel()
        } else {
            showQuickPanel()
        }
    }

    /// Opens the panel on `tab`; without one, on Inbox while a thread waits, else Ask (`quickPanelLanding`).
    func showQuickPanel(tab: QuickPanel.Tab? = nil) {
        quickPanel.tab = tab ?? QuickPanel.openingTab(waiting: waitingThreads.count,
                                                      landing: config.preferences.quickPanelLanding)
        quickPanel.sentNotice = nil
        if quickPanel.tab == .inbox {
            pruneInboxDismissals()
            let order = quickPanelInboxItems
            if quickPanel.selected == nil || !order.contains(where: { $0.id == quickPanel.selected }) {
                quickPanel.selected = order.first?.id
            }
        }
        QuickPanelController.shared.show(model: self)
    }

    func hideQuickPanel() {
        QuickPanelController.shared.hide()
        inbox.replyingTo = nil
    }

    /// The second chord: the window comes up, or the app hides when it is already what the user looks at.
    func toggleMainWindow() {
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" }
        switch QuickPanel.windowToggle(appActive: NSApp.isActive, windowVisible: main?.isVisible == true) {
        case .hide:
            NSApp.hide(nil)
        case .show:
            NSApp.activate()
            main?.makeKeyAndOrderFront(nil)
            AppDelegate.refocusTerminal()
        }
    }

    // MARK: Ask

    /// The scope the Ask field addresses (`QuickPanel.addressedScope`).
    var quickPanelScope: ScopeState? {
        QuickPanel.addressedScope(chosen: quickPanel.chosenScope, current: currentScope?.id, scopes: scopes.map(\.id))
            .flatMap(scope)
    }

    /// The orchestrator the Ask field writes to, when its scope has one.
    var quickPanelOrchestrator: ThreadSession? {
        guard let scope = quickPanelScope else { return nil }
        return UserMessage.orchestrator(of: scope.id, in: threads.map(\.record)).flatMap(session)
    }

    /// ⌃1…⌃9 in the panel: addresses the scope at `digit`; a slot no scope fills does nothing.
    func chooseQuickPanelScope(digit: Int) {
        guard let id = QuickPanel.scope(forDigit: digit, in: scopes.map(\.id)) else { return }
        quickPanel.chosenScope = id
    }

    /// ↩ in the Ask field: the text goes the way the palette's *Ask Orchestrator…* sends it, the panel says so and
    /// goes. `false` when nothing went (an empty message, a scope without an orchestrator).
    @discardableResult
    func sendFromQuickPanel() -> Bool {
        guard let orchestrator = quickPanelOrchestrator, sendMessage(quickPanel.draft, to: orchestrator.id) else { return false }
        quickPanel.draft = ""
        quickPanel.sentNotice = "Sent to the \(messageTargetName(orchestrator.id))"
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.quickPanel.sentNotice != nil else { return }
            self.hideQuickPanel()
        }
        return true
    }

    // MARK: Inbox

    /// The panel's Inbox: what blocks an agent first, then the rest (`Inbox.urgentFirst`).
    var quickPanelInboxItems: [Inbox.Item] {
        Inbox.urgentFirst(inboxItems)
    }

    /// ↩ on a row: the panel goes and the app comes up on the item, as the sheet's Open does.
    func openFromQuickPanel(_ item: Inbox.Item) {
        hideQuickPanel()
        NSApp.activate()
        openInboxItem(item)
    }
}
