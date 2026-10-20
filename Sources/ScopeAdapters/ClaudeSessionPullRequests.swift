import Foundation

/// The pull requests a Claude Code session opened, merged or linked: the transcript's `pr-link`, and the
/// `gitOperation.pr` a `Bash` call's `PostToolUse` reports (`gh pr create`, `gh pr merge`) — the transcript keeps no
/// result of a foreground command, so that one only comes from the hook.
///
/// Not a pull request model: the task's own (`LinkedPullRequest`, `PullRequestSet`) stays the one source of truth.
/// This only tells the app, the moment it happens, that the task's pull requests are worth asking `gh` about again.
public struct ClaudeSessionPullRequests: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var number: Int
        public var url: String?
        /// `owner/repo`, from the link or the URL.
        public var repository: String?
        /// `created`, `merged`, … as `gitOperation.pr.action` says; `nil` for a `pr-link`.
        public var action: String?
        public var at: Date?

        public init(number: Int, url: String? = nil, repository: String? = nil, action: String? = nil, at: Date? = nil) {
            self.number = number
            self.url = url
            self.repository = repository ?? url.flatMap(Self.repository(fromURL:))
            self.action = action
            self.at = at
        }

        /// Two reports of one pull request: same number, and the same repository when both name one.
        func isSame(as other: Entry) -> Bool {
            number == other.number && (repository == nil || other.repository == nil || repository == other.repository)
        }

        /// `https://github.com/acme/api/pull/12` → `acme/api`.
        static func repository(fromURL url: String) -> String? {
            guard let components = URL(string: url)?.pathComponents, components.count >= 5, components[3] == "pull" else { return nil }
            return "\(components[1])/\(components[2])"
        }
    }

    /// Oldest first, one per pull request.
    public private(set) var entries: [Entry] = []

    static let limit = 50

    public init() {}

    public mutating func apply(_ facts: ClaudeHookFacts) {
        guard facts.event == "PostToolUse", facts.toolName == "Bash",
              let pr = facts.toolResponse?["gitOperation"]?["pr"], let number = pr["number"]?.int else { return }
        record(Entry(number: number, url: pr["url"]?.nonEmptyString, action: pr["action"]?.nonEmptyString, at: facts.at))
    }

    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for case .pullRequest(let link) in records {
            record(Entry(number: link.number, url: link.url, repository: link.repository, at: link.at))
        }
    }

    /// The entries `self` gained or whose action moved since `previous`: what is worth a refresh.
    public func changes(since previous: ClaudeSessionPullRequests) -> [Entry] {
        entries.filter { entry in
            guard let known = previous.entries.first(where: { $0.isSame(as: entry) }) else { return true }
            return known.action != entry.action
        }
    }

    private mutating func record(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.isSame(as: entry) }) else {
            entries.append(entry)
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
            return
        }
        var known = entries[index]
        known.url = known.url ?? entry.url
        known.repository = known.repository ?? entry.repository
        // A `pr-link` written after `gh pr merge` says nothing new; it does not take the merge back.
        if let action = entry.action { known.action = action }
        if known.at == nil { known.at = entry.at }
        entries[index] = known
    }
}
