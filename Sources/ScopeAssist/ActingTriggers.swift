import Foundation
import ScopeCore

/// Triggers that act (spec §4.10): each one notices something in a thread's surroundings — the network came back, a
/// usage window reset, the pull request failed its checks — and proposes an action on one thread. Every proposal then
/// goes through one gate, `ActingTriggers.decide`, which is where loops die: a preference per trigger, once per key
/// (a failure, a SHA, a batch of comments), a debounce, an hourly cap per thread, never mid-turn, never while the
/// user types. A trigger is a pure function of its facts; adding one is a case of `ActingTrigger`, a detector that
/// returns a `Proposal`, and the code that gathers its facts.
public enum ActingTriggers {
    /// What a trigger wants done to its thread.
    public enum Action: Sendable, Equatable {
        /// Type `message` into the thread's prompt, keeping the user's draft (`ThreadSession.submit`).
        case send(String)
        /// The process is gone: restart the session on the same conversation, then submit `note`.
        case restart(note: String)
        /// Interrupt the open turn (Esc), then submit `message`.
        case interrupt(then: String)

        public var message: String {
            switch self {
            case .send(let text), .restart(let text), .interrupt(let text): text
            }
        }

        /// What the journal says it did.
        public var outcome: String {
            switch self {
            case .send: "sent"
            case .restart: "restarted"
            case .interrupt: "interrupted"
            }
        }
    }

    public struct Proposal: Sendable, Equatable {
        public var trigger: ActingTrigger
        public var thread: ThreadID
        /// What makes this occasion one: the failed turn, the head SHA, the last comment of a batch. The gate acts
        /// once per key, ever.
        public var key: String
        public var action: Action
        /// A journal token for what was read (`network`, `rate-limit`, `failing`, …).
        public var cause: String

        public init(trigger: ActingTrigger, thread: ThreadID, key: String, action: Action, cause: String) {
            self.trigger = trigger
            self.thread = thread
            self.key = key
            self.action = action
            self.cause = cause
        }
    }

    /// The thread a proposal targets, as the gate sees it.
    public struct ThreadFacts: Sendable, Equatable {
        public var id: ThreadID
        /// The process runs.
        public var alive: Bool
        /// Its session can be restarted on the same conversation (`ThreadRestart.unavailable == nil`).
        public var canRestart: Bool
        /// A turn is open: the agent is at work.
        public var inTurn: Bool
        /// It waits on the user: a question or a permission. The user owes it an answer, not Scope.
        public var waitingForUser: Bool
        /// The last time the user typed into it.
        public var lastUserInputAt: Date?
        /// The trigger whose message opened the turn in progress or the last one, if Scope opened it.
        public var turnOpenedBy: ActingTrigger?

        public init(id: ThreadID, alive: Bool = true, canRestart: Bool = false, inTurn: Bool = false,
                    waitingForUser: Bool = false, lastUserInputAt: Date? = nil, turnOpenedBy: ActingTrigger? = nil) {
            self.id = id
            self.alive = alive
            self.canRestart = canRestart
            self.inTurn = inTurn
            self.waitingForUser = waitingForUser
            self.lastUserInputAt = lastUserInputAt
            self.turnOpenedBy = turnOpenedBy
        }
    }

    public enum Verdict: Sendable, Equatable {
        case act
        /// Not now; the same proposal may come back and pass later (`busy`, `typing`, `debounce`, `waiting`).
        case hold(String)
        /// Never for this key (`off`, `done`, `no-thread`, `own-turn`).
        case skip(String)
        /// The hourly cap is reached for this trigger on this thread: Scope stops and tells the user.
        case capped

        /// The journal token.
        public var outcome: String {
            switch self {
            case .act: "act"
            case .hold: "held"
            case .skip: "skipped"
            case .capped: "capped"
            }
        }

        public var cause: String? {
            switch self {
            case .hold(let cause), .skip(let cause): cause
            case .act, .capped: nil
            }
        }
    }

    /// A user who typed into the thread this recently is at the keyboard: nothing is typed over them.
    public static let typingGrace: TimeInterval = 20

    /// Two acts of one trigger on one thread closer than this are one too many: a flapping network fails a turn, the
    /// relaunch fails it again a second later.
    public static func debounce(_ trigger: ActingTrigger) -> TimeInterval {
        switch trigger {
        case .connectionLost, .wake: 30
        case .usageLimit: 60
        case .ciFailed, .review, .stuck: 5 * 60
        case .conflicts: 10 * 60
        case .baseMoved: 30 * 60
        }
    }

    /// The gate. In order: the preference; once per key; a thread to act on (a dead one only for a restart); not
    /// while it waits on the user; not mid-turn unless the action is to interrupt it; not while the user types; the
    /// debounce; the hourly cap. A trigger never fires on a turn its own message opened when it judges that turn
    /// (`stuck`): its answer would be its own question again.
    public static func decide(_ proposal: Proposal, thread: ThreadFacts?, preference: ActingTriggerPreference,
                              ledger: ActingLedger, now: Date = .now) -> Verdict {
        guard preference.enabled else { return .skip("off") }
        if ledger.hasActed(proposal.trigger, on: proposal.thread, key: proposal.key) { return .skip("done") }
        guard let thread else { return .skip("no-thread") }
        if !thread.alive {
            guard case .restart = proposal.action, thread.canRestart else { return .skip("no-thread") }
        }
        if proposal.trigger == .stuck, thread.turnOpenedBy == .stuck { return .skip("own-turn") }
        if thread.waitingForUser { return .hold("waiting") }
        if thread.inTurn, thread.alive {
            guard case .interrupt = proposal.action else { return .hold("busy") }
        }
        if let typed = thread.lastUserInputAt, now.timeIntervalSince(typed) < typingGrace { return .hold("typing") }
        if let last = ledger.lastAct(proposal.trigger, on: proposal.thread),
           now.timeIntervalSince(last) < debounce(proposal.trigger) { return .hold("debounce") }
        if ledger.acts(proposal.trigger, on: proposal.thread, since: now.addingTimeInterval(-3600)) >= preference.hourlyCap {
            return .capped
        }
        return .act
    }
}

/// What the triggers did, kept under `SCOPE_HOME` so a relaunch of the app does not act again on the same SHA or
/// the same failure: every act with its key, and every time the user was told instead.
public struct ActingLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var trigger: ActingTrigger
        public var thread: String
        public var key: String
        public var at: Date

        public init(trigger: ActingTrigger, thread: String, key: String, at: Date) {
            self.trigger = trigger
            self.thread = thread
            self.key = key
            self.at = at
        }
    }

    public var acts: [Entry]
    /// Notifications sent instead of an act: past the cap (`key` = `cap`), or with no thread to act on.
    public var notices: [Entry]
    /// How far a trigger has read a stream, by `trigger:subject` — the newest review comment handed to a task's
    /// thread. Optional on disk: a ledger written before it existed decodes.
    public var marks: [String: Date]?

    public init(acts: [Entry] = [], notices: [Entry] = [], marks: [String: Date]? = nil) {
        self.acts = acts
        self.notices = notices
        self.marks = marks
    }

    public func mark(_ trigger: ActingTrigger, _ subject: String) -> Date? {
        marks?["\(trigger.rawValue):\(subject)"]
    }

    public mutating func setMark(_ trigger: ActingTrigger, _ subject: String, to date: Date) {
        var all = marks ?? [:]
        all["\(trigger.rawValue):\(subject)"] = date
        marks = all
    }

    /// Entries older than this go: a SHA two weeks old is not coming back.
    public static let retention: TimeInterval = 14 * 24 * 3600
    static let limit = 2_000

    public func hasActed(_ trigger: ActingTrigger, on thread: ThreadID, key: String) -> Bool {
        acts.contains { $0.trigger == trigger && $0.thread == thread.rawValue && $0.key == key }
    }

    public func lastAct(_ trigger: ActingTrigger, on thread: ThreadID) -> Date? {
        acts.filter { $0.trigger == trigger && $0.thread == thread.rawValue }.map(\.at).max()
    }

    public func acts(_ trigger: ActingTrigger, on thread: ThreadID, since: Date) -> Int {
        acts.count { $0.trigger == trigger && $0.thread == thread.rawValue && $0.at >= since }
    }

    /// Acts of every trigger on `thread` since `since`: what the visible trace counts.
    public func acts(on thread: ThreadID, since: Date) -> [Entry] {
        acts.filter { $0.thread == thread.rawValue && $0.at >= since }
    }

    public mutating func recordAct(_ trigger: ActingTrigger, on thread: ThreadID, key: String, at: Date) {
        acts.append(Entry(trigger: trigger, thread: thread.rawValue, key: key, at: at))
        prune(now: at)
    }

    /// Whether the user was already told about `key` for this trigger and thread since `since`.
    public func hasNotified(_ trigger: ActingTrigger, on thread: ThreadID, key: String, since: Date = .distantPast) -> Bool {
        notices.contains { $0.trigger == trigger && $0.thread == thread.rawValue && $0.key == key && $0.at >= since }
    }

    public mutating func recordNotice(_ trigger: ActingTrigger, on thread: ThreadID, key: String, at: Date) {
        notices.append(Entry(trigger: trigger, thread: thread.rawValue, key: key, at: at))
        prune(now: at)
    }

    /// The key of the cap notice: one per trigger, thread and hour of the clock.
    public static func capKey(at date: Date) -> String {
        "cap@\(Int(date.timeIntervalSince1970 / 3600))"
    }

    /// A thread closed for good leaves nothing behind.
    public mutating func forget(_ thread: ThreadID) {
        acts.removeAll { $0.thread == thread.rawValue }
        notices.removeAll { $0.thread == thread.rawValue }
    }

    mutating func prune(now: Date) {
        let floor = now.addingTimeInterval(-Self.retention)
        acts.removeAll { $0.at < floor }
        notices.removeAll { $0.at < floor }
        if acts.count > Self.limit { acts.removeFirst(acts.count - Self.limit) }
        if notices.count > Self.limit { notices.removeFirst(notices.count - Self.limit) }
    }
}

/// `SCOPE_HOME/triggers.json`: the ledger, read once and written after every change.
public actor ActingLedgerStore {
    public nonisolated let url: URL

    public init(home: URL) {
        url = home.appending(path: "triggers.json", directoryHint: .notDirectory)
    }

    public func load() -> ActingLedger {
        guard let data = try? Data(contentsOf: url) else { return ActingLedger() }
        return (try? Self.decoder.decode(ActingLedger.self, from: data)) ?? ActingLedger()
    }

    public func save(_ ledger: ActingLedger) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(ledger).write(to: url, options: .atomic)
        } catch {
            // Lost on disk means one extra act after a relaunch at worst; the in-memory ledger still holds.
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
