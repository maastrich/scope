import Foundation
import ScopeCore
import ScopeGit

/// What closing a thread or archiving a task would lose, so the app asks only then — and never for a thread that
/// has nothing running or a task whose pull request has merged.
///
/// The question is the second line of defence; the first is that no destructive control sits under the pointer on
/// a sidebar row (the hover controls are a menu), and the last is the undo (`UndoLedger`): a close or an archive is
/// taken back in one keystroke while its record is still kept. What cannot be undone — a task closed for good — is
/// behind a context menu and the same question.
public enum CloseGuard {
    /// One reason a close or an archive is not free.
    public enum Risk: Equatable, Sendable, Hashable {
        /// An agent is in the middle of a turn: hanging it up loses the turn, not just the process.
        case interruptsTurn
        /// A driver that reports nothing (a shell) has a live process; what it is doing is unknown.
        case runningProcess
        /// A sandbox has uncommitted changes. An archive salvages them, but the task leaves the sidebar with them.
        case uncommittedChanges
        /// A pull request is still open: the task is under review, not done.
        case openPullRequest(number: Int)
    }

    /// Closing a thread. `reportsActivity` is whether its driver delivers turn events: without them a live process
    /// is taken for working, since a shell in the middle of a build looks the same as an idle one.
    public static func threadRisks(isAlive: Bool, isWorking: Bool, reportsActivity: Bool) -> [Risk] {
        guard isAlive else { return [] }
        if isWorking { return [.interruptsTurn] }
        return reportsActivity ? [] : [.runningProcess]
    }

    /// Archiving or closing a task, from what its row already knows (`TaskFacts`).
    public static func taskRisks(_ facts: TaskFacts) -> [Risk] {
        var risks: [Risk] = []
        if facts.threads.contains(.running) { risks.append(.interruptsTurn) }
        if facts.isDirty { risks.append(.uncommittedChanges) }
        for pullRequest in facts.pullRequests where pullRequest.state == .open {
            risks.append(.openPullRequest(number: pullRequest.number))
        }
        return risks
    }

    /// Whether to ask: the preference is on and there is something to lose. Off, nothing ever asks — the undo
    /// still stands.
    public static func shouldConfirm(_ risks: [Risk], preference: Bool) -> Bool {
        preference && !risks.isEmpty
    }

    /// The sentences of the alert, one per risk, in the order they were found.
    public static func describe(_ risks: [Risk]) -> [String] {
        risks.map { risk in
            switch risk {
            case .interruptsTurn: "An agent is in the middle of a turn; it will be interrupted."
            case .runningProcess: "A process is still running; it will be sent SIGHUP."
            case .uncommittedChanges: "There are uncommitted changes. They are saved under refs/scope/salvage/ and come back with Restore."
            case .openPullRequest(let number): "Pull request #\(number) is still open."
            }
        }
    }
}

/// The actions the user can take back, newest last, each kept for `window` after it was done. A pop hands back the
/// most recent one still inside its window; what expired is dropped on the way. Dates are passed in, so the tests
/// drive the clock.
public struct UndoLedger<Entry> {
    public struct Item {
        public var id: String
        public var entry: Entry
        public var at: Date
        /// The user did it: ⌘Z and ⇧⌘T may take it back for `keyWindow`. An agent's close or archive is offered by
        /// the toast and the palette only — a ⌘Z typed into a text field must not rebuild a task an agent archived.
        public var byKeyboard: Bool

        public init(id: String, entry: Entry, at: Date, byKeyboard: Bool = true) {
            self.id = id
            self.entry = entry
            self.at = at
            self.byKeyboard = byKeyboard
        }
    }

    public private(set) var items: [Item] = []
    public var window: TimeInterval
    /// How long a shortcut keeps claiming its key after the action: short, since ⌘Z belongs to the text views and
    /// ⇧⌘T to New Task the rest of the time.
    public var keyWindow: TimeInterval

    public init(window: TimeInterval, keyWindow: TimeInterval = 30) {
        self.window = window
        self.keyWindow = keyWindow
    }

    /// Adds an action; one with the same id replaces the earlier entry (a thread closed, reopened and closed again).
    public mutating func push(id: String, entry: Entry, at: Date, byKeyboard: Bool = true) {
        items.removeAll { $0.id == id }
        items.append(Item(id: id, entry: entry, at: at, byKeyboard: byKeyboard))
    }

    /// The action a shortcut would take back at `now`, if it may: the newest one matching `predicate`, done by the
    /// user, inside `keyWindow`. `nil` leaves the key to whatever else owns it.
    public func keyed(at now: Date, where predicate: (Entry) -> Bool = { _ in true }) -> Item? {
        guard let newest = live(at: now).last(where: { predicate($0.entry) }),
              newest.byKeyboard, now.timeIntervalSince(newest.at) < keyWindow else { return nil }
        return newest
    }

    /// Takes the most recent action still inside its window — the one ⌘Z undoes.
    public mutating func pop(at now: Date) -> Entry? {
        expire(at: now)
        return items.popLast()?.entry
    }

    /// Takes the most recent action matching `predicate` (⇧⌘T only reopens threads).
    public mutating func pop(at now: Date, where predicate: (Entry) -> Bool) -> Entry? {
        expire(at: now)
        guard let index = items.lastIndex(where: { predicate($0.entry) }) else { return nil }
        return items.remove(at: index).entry
    }

    /// Takes one action by id (a toast's button).
    public mutating func take(id: String, at now: Date) -> Entry? {
        expire(at: now)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index).entry
    }

    public mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    public mutating func expire(at now: Date) {
        items.removeAll { now.timeIntervalSince($0.at) >= window }
    }

    /// The actions still inside their window at `now`, oldest first.
    public func live(at now: Date) -> [Item] {
        items.filter { now.timeIntervalSince($0.at) < window }
    }

    public func isEmpty(at now: Date) -> Bool { live(at: now).isEmpty }
}
