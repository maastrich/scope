import Foundation

/// The quick panel (spec §7): the small floating window a system-wide hotkey opens over whatever is on screen,
/// with *Ask* — a message to a scope's orchestrator — and *Inbox* — what needs the owner. The decisions that need
/// no window live here: which tab it opens on, which scope the message goes to, what the second chord does to the
/// main window.
public enum QuickPanel {
    public enum Tab: String, Codable, Sendable, CaseIterable {
        case ask
        case inbox
    }

    /// Where the panel lands when opened — a preference.
    public enum Landing: String, Codable, Sendable, CaseIterable {
        /// Inbox while a thread waits for the owner, Ask otherwise. The default.
        case inboxWhenWaiting
        case ask
        case inbox

        public var title: String {
            switch self {
            case .inboxWhenWaiting: "Inbox when something waits, else Ask"
            case .ask: "Always Ask"
            case .inbox: "Always Inbox"
            }
        }
    }

    /// The tab the panel opens on: `waiting` is how many threads need the owner right now.
    public static func openingTab(waiting: Int, landing: Landing) -> Tab {
        switch landing {
        case .inboxWhenWaiting: waiting > 0 ? .inbox : .ask
        case .ask: .ask
        case .inbox: .inbox
        }
    }

    /// The scope the Ask field addresses. `chosen` is what the user picked in the panel (⌃1…9, a tile) and wins
    /// while it is still a scope; else the app's current scope; else the first declared. `nil` without any scope.
    public static func addressedScope(chosen: ScopeID?, current: ScopeID?, scopes: [ScopeID]) -> ScopeID? {
        if let chosen, scopes.contains(chosen) { return chosen }
        if let current, scopes.contains(current) { return current }
        return scopes.first
    }

    /// ⌃1…⌃9 inside the panel: the scope at `digit` in the declared order, `nil` for a slot no scope fills.
    public static func scope(forDigit digit: Int, in scopes: [ScopeID]) -> ScopeID? {
        guard (1...9).contains(digit), scopes.indices.contains(digit - 1) else { return nil }
        return scopes[digit - 1]
    }

    /// What the window chord does.
    public enum WindowToggle: Sendable, Equatable {
        /// Bring the app and its main window to the front.
        case show
        /// Hide the app, as ⌘H would.
        case hide
    }

    /// The main window comes up unless it is already the one the user is looking at — then it goes.
    public static func windowToggle(appActive: Bool, windowVisible: Bool) -> WindowToggle {
        appActive && windowVisible ? .hide : .show
    }
}
