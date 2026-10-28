import Foundation

/// When a pull request's reviews are worth waking the task's thread for, and which comments it gets: plain values in,
/// a batch out, so "one wake per batch" and what is ignored are under test without GitHub.
public enum ReviewWake {
    public enum Kind: String, Sendable, Equatable {
        /// A review's own body (`gh pr review`, Copilot's overview).
        case review
        /// A comment on a line of the diff.
        case inline
        /// A comment on the pull request's conversation.
        case conversation
    }

    public struct Item: Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var author: String
        public var body: String
        public var at: Date
        public var url: URL?
        /// `CHANGES_REQUESTED`, `COMMENTED`, `APPROVED` for a review.
        public var state: String?
        public var path: String?
        public var line: Int?
        /// The review thread it belongs to is resolved, or its last word is the viewer's: handled.
        public var handled: Bool

        public init(id: String, kind: Kind, author: String, body: String, at: Date, url: URL? = nil, state: String? = nil,
                    path: String? = nil, line: Int? = nil, handled: Bool = false) {
            self.id = id
            self.kind = kind
            self.author = author
            self.body = body
            self.at = at
            self.url = url
            self.state = state
            self.path = path
            self.line = line
            self.handled = handled
        }
    }

    public struct Batch: Sendable, Equatable {
        public var comments: [ActingPrompts.ReviewComment]
        /// When the newest comment of the batch was written: the watermark once it is handed over.
        public var newest: Date
        /// The gate's key: one wake per batch.
        public var key: String
    }

    /// A reviewer posts a review and its inline comments within seconds, and a human adds a few more over a minute:
    /// the batch goes once nothing new came for this long.
    public static let quiet: TimeInterval = 120

    /// GitHub's Copilot reviewer, whatever its login looks like on this host.
    public static func isCopilot(_ login: String) -> Bool { login.lowercased().contains("copilot") }

    /// Bots that post previews, coverage and the like: nothing to address. Copilot is the exception.
    public static func isIgnoredBot(_ login: String) -> Bool {
        let lower = login.lowercased()
        return !isCopilot(lower) && (lower.hasSuffix("[bot]") || lower.hasSuffix("-bot") || lower == "github-actions")
    }

    /// Whether `item` is something for the thread to address. The viewer is both the user and every thread (they
    /// push with the user's `gh` login), so the viewer's conversation comments and review bodies — summaries, "done"
    /// — are ignored; a line comment by the viewer is a request about the code and counts. An approval without words
    /// and Copilot's overview (`Copilot reviewed N out of M files…`) ask for nothing.
    public static func matters(_ item: Item, viewer: String?) -> Bool {
        guard !item.handled, !isIgnoredBot(item.author) else { return false }
        let text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let byViewer = viewer.map { $0.caseInsensitiveCompare(item.author) == .orderedSame } ?? false
        switch item.kind {
        case .inline:
            return !text.isEmpty
        case .conversation:
            return !byViewer && !text.isEmpty
        case .review:
            if byViewer { return false }
            if item.state == "CHANGES_REQUESTED" { return true }
            if item.state == "APPROVED" || text.isEmpty { return false }
            if isCopilot(item.author), text.lowercased().contains("reviewed") { return false }
            return true
        }
    }

    /// The batch to hand over, `nil` while there is none or it is still coming in: every item that matters and is
    /// newer than `handledThrough`, once the newest is `quiet` old.
    public static func batch(_ items: [Item], viewer: String?, handledThrough: Date?, now: Date = .now) -> Batch? {
        let fresh = items.filter { item in
            (handledThrough.map { item.at > $0 } ?? true) && matters(item, viewer: viewer)
        }.sorted { $0.at < $1.at }
        guard let newest = fresh.last, now.timeIntervalSince(newest.at) >= quiet else { return nil }
        let comments = fresh.map { item in
            ActingPrompts.ReviewComment(
                author: isCopilot(item.author) ? "Copilot" : item.author,
                location: item.path.map { path in item.line.map { "\(path):\($0)" } ?? path },
                excerpt: item.body, url: item.url, state: item.state)
        }
        return Batch(comments: comments, newest: newest.at, key: "review@\(newest.id)")
    }
}

/// When a failing pull request wakes its idle thread.
public enum CheckWake {
    /// A thread whose turn ended this recently is still being followed — by the user reading it, or by the agent
    /// about to look at its own push.
    public static let idleAfter: TimeInterval = 120
    /// Checks still running beside a failure are waited for this long, so the message lists every failure at once.
    public static let pendingGrace: TimeInterval = 10 * 60

    /// `true` when the checks failed and the thread is idle: no turn open, the last one over for `idleAfter`. With
    /// checks still pending, only once the failure is `pendingGrace` old.
    public static func isDue(failing: Int, pending: Int, failingSince: Date?, threadIdleSince: Date?, now: Date = .now) -> Bool {
        guard failing > 0, let idle = threadIdleSince, now.timeIntervalSince(idle) >= idleAfter else { return false }
        if pending > 0 {
            guard let since = failingSince, now.timeIntervalSince(since) >= pendingGrace else { return false }
        }
        return true
    }
}
