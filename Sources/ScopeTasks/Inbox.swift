import Foundation
import ScopeCore
import ScopeGit

/// What needs the owner, across every scope: the threads asking something, the turns that finished or failed while
/// nobody looked, the pull requests ready to merge or failing their checks, and the tasks put away on their merge.
///
/// Pure: the app hands in what it holds (`ThreadInput`, `TaskInput`) and the dismissals the user made, and gets the
/// items back in the order they are drawn. A thread item lives as long as the thread's state says so — answering,
/// looking at it or Mark as Read moves the state and the item goes. A task item has no state of its own to clear, so
/// *Mark Read* records a dismissal against its `fingerprint`: the item stays away until what it says changes (failing
/// checks that turn green, then red again, come back).
public enum Inbox {
    /// How long a task archived on its merge stays listed, for its Restore.
    public static let archivedWindow: TimeInterval = 3 * 86_400

    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// The agent asked a question (`waiting(input)`).
        case question
        /// The agent needs a permission (`waiting(permission)`).
        case permission
        /// A turn ended and nobody has looked at it (`done`).
        case reply
        /// A turn ended on an error (`failed`).
        case failure
        /// The task's pull request is open, mergeable and its checks pass.
        case readyToMerge
        /// The task's pull request has a failing check.
        case checksFailing
        /// The task was archived because its pull request merged.
        case archivedOnMerge

        /// Thread items clear with the thread's state; the others with a dismissal.
        public var isThreadItem: Bool {
            switch self {
            case .question, .permission, .reply, .failure: true
            case .readyToMerge, .checksFailing, .archivedOnMerge: false
            }
        }
    }

    /// One thread as the app sees it.
    public struct ThreadInput: Sendable, Equatable {
        public var id: ThreadID
        public var scopeID: ScopeID
        public var taskID: TaskID?
        public var title: String
        public var state: ThreadState
        /// When the thread entered `state`: the end of its last turn, or the request it waits on.
        public var since: Date
        /// The question, the permission asked, the reply or the error, as the app words it; its first line is shown.
        public var text: String?

        public init(id: ThreadID, scopeID: ScopeID, taskID: TaskID? = nil, title: String, state: ThreadState, since: Date,
                    text: String? = nil) {
            self.id = id
            self.scopeID = scopeID
            self.taskID = taskID
            self.title = title
            self.state = state
            self.since = since
            self.text = text
        }
    }

    /// One task and its pull request as last read from GitHub.
    public struct TaskInput: Sendable, Equatable {
        public struct PullRequestInput: Sendable, Equatable {
            public var number: Int
            public var title: String
            public var url: URL
            /// `open`, `merged`, `closed`.
            public var state: PullRequest.State
            public var checks: PullRequest.Checks
            public var mergeable: PullRequest.Mergeable
            public var isDraft: Bool
            /// The names of the failing checks, for the item's text.
            public var failingChecks: [String]
            /// When GitHub last saw a change, else when the app read it.
            public var updatedAt: Date

            public init(number: Int, title: String, url: URL, state: PullRequest.State, checks: PullRequest.Checks,
                        mergeable: PullRequest.Mergeable, isDraft: Bool = false, failingChecks: [String] = [],
                        updatedAt: Date) {
                self.number = number
                self.title = title
                self.url = url
                self.state = state
                self.checks = checks
                self.mergeable = mergeable
                self.isDraft = isDraft
                self.failingChecks = failingChecks
                self.updatedAt = updatedAt
            }
        }

        public var id: TaskID
        public var scopeID: ScopeID
        public var name: String
        public var pullRequest: PullRequestInput?
        /// `nil` for an open task.
        public var archivedAt: Date?
        /// Being archived or closed right now: not listed either way until it settles.
        public var isDismantling: Bool

        public init(id: TaskID, scopeID: ScopeID, name: String, pullRequest: PullRequestInput? = nil,
                    archivedAt: Date? = nil, isDismantling: Bool = false) {
            self.id = id
            self.scopeID = scopeID
            self.name = name
            self.pullRequest = pullRequest
            self.archivedAt = archivedAt
            self.isDismantling = isDismantling
        }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        /// Stable across refreshes: one per thread, and at most two per task (its pull request, its archive).
        public var id: String
        public var kind: Kind
        public var scopeID: ScopeID
        public var taskID: TaskID?
        public var threadID: ThreadID?
        /// The thread's title, or the task's name for a task item.
        public var title: String
        /// One line: the question, the reply's first line, the error, the checks.
        public var detail: String?
        public var at: Date
        /// What a dismissal is made against: the item is back once this changes.
        public var fingerprint: String
        public var pullRequestURL: URL?
        public var pullRequestNumber: Int?
    }

    /// Items of one scope, newest first.
    public struct Group: Sendable, Equatable, Identifiable {
        public var scopeID: ScopeID
        public var items: [Item]
        public var id: ScopeID { scopeID }
    }

    /// Every item, newest first, one per key.
    public static func items(threads: [ThreadInput], tasks: [TaskInput], dismissed: Dismissals = Dismissals(),
                             now: Date = .now, archivedWindow: TimeInterval = archivedWindow) -> [Item] {
        var byID: [String: Item] = [:]
        for thread in threads {
            guard let item = item(for: thread) else { continue }
            byID[item.id] = newer(byID[item.id], item)
        }
        for task in tasks where !task.isDismantling {
            for item in items(for: task, now: now, archivedWindow: archivedWindow) where !dismissed.hides(item) {
                byID[item.id] = newer(byID[item.id], item)
            }
        }
        return byID.values.sorted(by: order)
    }

    /// `items` by scope: the scope with the newest item first, `scopeOrder` (the sidebar's) breaking ties, items
    /// newest first inside each.
    public static func groups(_ items: [Item], scopeOrder: [ScopeID] = []) -> [Group] {
        let rank = Dictionary(scopeOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [ScopeID: [Item]] = [:]
        for item in items { groups[item.scopeID, default: []].append(item) }
        return groups
            .map { Group(scopeID: $0.key, items: $0.value.sorted(by: order)) }
            .sorted { lhs, rhs in
                let l = lhs.items[0].at, r = rhs.items[0].at
                if l != r { return l > r }
                return (rank[lhs.scopeID] ?? .max, lhs.scopeID.rawValue) < (rank[rhs.scopeID] ?? .max, rhs.scopeID.rawValue)
            }
    }

    /// The items in the order the list draws them (`groups` flattened): what j/k walk.
    public static func drawnOrder(_ items: [Item], scopeOrder: [ScopeID] = []) -> [Item] {
        groups(items, scopeOrder: scopeOrder).flatMap(\.items)
    }

    /// The first line worth reading of `text`: blank lines and Markdown decoration skipped, cut at `limit` characters.
    public static func headline(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // A heading, a quote, a list bullet or a rule says nothing on its own: drop the marker, keep the words.
            while let first = line.first, "#>*-_`".contains(first) { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }

    // MARK: Items

    static func item(for thread: ThreadInput) -> Item? {
        let kind: Kind
        switch thread.state {
        case .waiting(.input): kind = .question
        case .waiting(.permission): kind = .permission
        case .done: kind = .reply
        case .failed: kind = .failure
        case .idle, .running, .exited: return nil
        }
        return Item(id: "thread:\(thread.id.rawValue)", kind: kind, scopeID: thread.scopeID, taskID: thread.taskID,
                    threadID: thread.id, title: thread.title, detail: headline(thread.text), at: thread.since,
                    fingerprint: "\(kind.rawValue)@\(thread.since.timeIntervalSinceReferenceDate)")
    }

    static func items(for task: TaskInput, now: Date, archivedWindow: TimeInterval) -> [Item] {
        guard let pr = task.pullRequest else { return [] }
        if let archivedAt = task.archivedAt {
            guard pr.state == .merged, now.timeIntervalSince(archivedAt) < archivedWindow else { return [] }
            return [Item(id: "task:\(task.id.rawValue):archived", kind: .archivedOnMerge, scopeID: task.scopeID,
                         taskID: task.id, threadID: nil, title: task.name, detail: "#\(pr.number) merged · \(pr.title)",
                         at: archivedAt, fingerprint: "archived@\(archivedAt.timeIntervalSinceReferenceDate)",
                         pullRequestURL: pr.url, pullRequestNumber: pr.number)]
        }
        guard pr.state == .open else { return [] }
        let kind: Kind
        let detail: String
        if pr.checks == .failing {
            kind = .checksFailing
            let names = pr.failingChecks
            detail = names.isEmpty ? "#\(pr.number) checks failing"
                : "#\(pr.number) failing: " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
        } else if !pr.isDraft, pr.mergeable == .mergeable, pr.checks == .passing || pr.checks == .none {
            kind = .readyToMerge
            detail = "#\(pr.number) ready to merge · \(pr.title)"
        } else {
            return []
        }
        return [Item(id: "task:\(task.id.rawValue):pr", kind: kind, scopeID: task.scopeID, taskID: task.id, threadID: nil,
                     title: task.name, detail: detail, at: pr.updatedAt,
                     fingerprint: "\(kind.rawValue)#\(pr.number)" + (kind == .checksFailing ? ":" + pr.failingChecks.sorted().joined(separator: ",") : ""),
                     pullRequestURL: pr.url, pullRequestNumber: pr.number)]
    }

    private static func newer(_ existing: Item?, _ candidate: Item) -> Item {
        guard let existing else { return candidate }
        return existing.at >= candidate.at ? existing : candidate
    }

    /// Newest first; the id keeps two items of the same instant in a stable order.
    private static func order(_ lhs: Item, _ rhs: Item) -> Bool {
        lhs.at != rhs.at ? lhs.at > rhs.at : lhs.id < rhs.id
    }

    // MARK: Dismissals

    /// The task items the user marked read, each against the fingerprint it had then.
    public struct Dismissals: Codable, Sendable, Equatable {
        public var version = 1
        public var fingerprints: [String: String] = [:]

        public init(fingerprints: [String: String] = [:]) {
            self.fingerprints = fingerprints
        }

        public func hides(_ item: Item) -> Bool {
            fingerprints[item.id] == item.fingerprint
        }

        /// Thread items are cleared through their thread (Mark as Read), never here.
        public mutating func dismiss(_ item: Item) {
            guard !item.kind.isThreadItem else { return }
            fingerprints[item.id] = item.fingerprint
        }

        /// Drops what no longer hides anything: an item gone, or one whose fingerprint moved on. Without this a
        /// dismissal of failing checks would hide them again the next time they fail the same way, after a green run.
        /// `candidates` are the task items before dismissals (`Inbox.items` with no dismissals).
        public func pruned(keeping candidates: [Item]) -> Dismissals {
            let current = Dictionary(candidates.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
            return Dismissals(fingerprints: fingerprints.filter { current[$0.key] == $0.value })
        }
    }
}

/// `<home>/inbox.json`: the Inbox dismissals. Losing it only brings dismissed items back.
public actor InboxDismissalStore {
    public nonisolated let url: URL

    public init(home: URL) {
        url = home.appending(path: "inbox.json", directoryHint: .notDirectory)
    }

    public func load() -> Inbox.Dismissals {
        (try? JSONStore.load(Inbox.Dismissals.self, from: url)) ?? Inbox.Dismissals()
    }

    public func save(_ dismissals: Inbox.Dismissals) {
        do {
            try JSONStore.save(dismissals, to: url)
        } catch {
            Log.tasks.error("inbox dismissals write failed: \(String(describing: error))")
        }
    }
}
