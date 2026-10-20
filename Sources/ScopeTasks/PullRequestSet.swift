import Foundation
import ScopeCore
import ScopeGit

/// A task's pull requests taken together: their order, the one a single button acts on, what they say as a whole.
///
/// A task can carry several — one per repository, two on the same branch (one closed, one reopened), a stack, a docs
/// pull request next to a prototype. Every surface that has room for one thing (a sidebar glyph, an archive decision,
/// a summary's outcome) reads it from here, so the rules are in one place and under test.
public enum PullRequestSet {
    /// A stable order, independent of what GitHub says this minute: the task's repositories in their order, then the
    /// number. A link without a repository (written before it was kept) counts as the first repository's.
    public static func ordered<T>(_ items: [T], repoOrder: [String], repo: (T) -> String?, number: (T) -> Int) -> [T] {
        let rank = Dictionary(repoOrder.map(TaskRepo.normalize).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let l = (rank[repo(lhs.element).map(TaskRepo.normalize) ?? ""] ?? Int.max, number(lhs.element), lhs.offset)
            let r = (rank[repo(rhs.element).map(TaskRepo.normalize) ?? ""] ?? Int.max, number(rhs.element), rhs.offset)
            return l < r
        }.map(\.element)
    }

    public static func ordered(_ links: [LinkedPullRequest], repoOrder: [String]) -> [LinkedPullRequest] {
        ordered(links, repoOrder: repoOrder, repo: \.repo, number: \.number)
    }

    /// `links` added to `existing`: one with the URL of an existing link replaces it in place (a repository it did
    /// not know is kept); the others are appended in their order.
    public static func merging(_ existing: [LinkedPullRequest], with links: [LinkedPullRequest]) -> [LinkedPullRequest] {
        var result = existing
        for var link in links {
            if let index = result.firstIndex(where: { $0.url == link.url }) {
                if link.repo == nil { link.repo = result[index].repo }
                result[index] = link
            } else {
                result.append(link)
            }
        }
        return result
    }

    /// The one to open, merge or refresh when nothing picked one: the first open, else the first merged, else the
    /// first. In the order given, which is `ordered`'s.
    public static func primary(_ links: [LinkedPullRequest]) -> LinkedPullRequest? {
        links.first(where: \.isOpen) ?? links.first(where: \.isMerged) ?? links.first
    }

    /// The state of the set: `open` while any is open (work is still out), else `merged` once any merged (work
    /// landed), else `closed` (every one dropped); `nil` for none. `nil` states read as `open`: a link is made of an
    /// open pull request, and GitHub was never asked since.
    public static func aggregateState(_ states: [String?]) -> String? {
        guard !states.isEmpty else { return nil }
        let states = states.map { $0 ?? "open" }
        if states.contains("open") { return "open" }
        if states.contains("merged") { return "merged" }
        return "closed"
    }

    /// Merged or closed, every one of them: nothing left to watch on GitHub.
    public static func isSettled(_ states: [String?]) -> Bool {
        let state = aggregateState(states)
        return state != nil && state != "open"
    }

    /// One line for several pull requests — `2 PRs · 1 merged · 1 checks failing` — the counts of what matters
    /// most first; `nil` for one or none, whose single state the row already says.
    public static func caption(_ facts: [PullRequestFacts]) -> String? {
        guard facts.count > 1 else { return nil }
        var parts = ["\(facts.count) PRs"]
        let open = facts.filter { $0.state == .open }
        let merged = facts.filter { $0.state == .merged }.count
        let closed = facts.filter { $0.state == .closed }.count
        let conflicted = open.filter { $0.mergeable == .conflicting }.count
        let failing = open.filter { $0.mergeable != .conflicting && $0.checks == .failing }.count
        let running = open.filter { $0.mergeable != .conflicting && $0.checks == .pending }.count
        let passed = open.filter { $0.mergeable != .conflicting && $0.checks == .passing }.count
        let drafts = open.filter { $0.mergeable != .conflicting && $0.checks == .none && $0.isDraft }.count
        let quiet = open.count - conflicted - failing - running - passed - drafts
        if merged > 0 { parts.append("\(merged) merged") }
        if conflicted > 0 { parts.append("\(conflicted) conflicting") }
        if failing > 0 { parts.append("\(failing) checks failing") }
        if running > 0 { parts.append("\(running) checks running") }
        if passed > 0 { parts.append("\(passed) checks passed") }
        if drafts > 0 { parts.append("\(drafts) draft") }
        if quiet > 0 { parts.append("\(quiet) open") }
        if closed > 0 { parts.append("\(closed) closed") }
        return parts.joined(separator: " · ")
    }

    // MARK: One pull request, read at a glance

    /// The checks of one pull request counted: `✗ 1 / 4` says more than *checks failing*. Skipped and neutral
    /// checks count for nothing, as `PullRequest.Checks` already has it.
    public struct CheckTally: Sendable, Equatable {
        public var passed = 0
        public var failed = 0
        public var pending = 0
        public var skipped = 0

        public init(passed: Int = 0, failed: Int = 0, pending: Int = 0, skipped: Int = 0) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
            self.skipped = skipped
        }

        /// The checks that count.
        public var total: Int { passed + failed + pending }

        /// `✗ 1 / 4` while any failed, `● 2 / 4` while any still runs, `✓ 4 / 4` when all passed; `nil` with no check
        /// that counts. The glyphs are `PullRequest.Checks`'s, so a row and a chip read the same.
        public var caption: String? {
            guard total > 0 else { return nil }
            if failed > 0 { return "✗ \(failed) / \(total)" }
            if pending > 0 { return "● \(passed) / \(total)" }
            return "✓ \(passed) / \(total)"
        }

        /// The fold the caption reads: what colours it.
        public var checks: PullRequest.Checks {
            guard total > 0 else { return .none }
            if failed > 0 { return .failing }
            return pending > 0 ? .pending : .passing
        }
    }

    public static func tally(_ runs: [PullRequestCheck]) -> CheckTally {
        var tally = CheckTally()
        for run in runs {
            switch run.state {
            case .passing: tally.passed += 1
            case .failing: tally.failed += 1
            case .pending: tally.pending += 1
            case .skipped: tally.skipped += 1
            }
        }
        return tally
    }

    /// What one pull request asks of you now, in one word for the foot of the card: the first that applies, from
    /// the most blocking down. A merged or closed one asks nothing.
    public enum Verdict: Sendable, Equatable {
        case merged, closed, conflicting
        case checksFailing(Int)
        case changesRequested, draft, checksRunning, reviewNeeded, ready, open

        public var label: String {
            switch self {
            case .merged: "Merged"
            case .closed: "Closed"
            case .conflicting: "Conflicts with the base"
            case .checksFailing(let count): count == 1 ? "1 check failing" : "\(count) checks failing"
            case .changesRequested: "Changes requested"
            case .draft: "Draft"
            case .checksRunning: "Checks running"
            case .reviewNeeded: "Ready to merge · review needed"
            case .ready: "Ready to merge"
            case .open: "Open"
            }
        }

        /// Whether the agent can do something about it from the thread: fix conflicts, fix the checks, merge.
        public var asksTheAgent: Bool {
            switch self {
            case .conflicting, .checksFailing, .ready, .reviewNeeded: true
            case .merged, .closed, .changesRequested, .draft, .checksRunning, .open: false
            }
        }
    }

    public static func verdict(state: PullRequest.State, isDraft: Bool, mergeable: PullRequest.Mergeable,
                               tally: CheckTally, review: PullRequest.ReviewDecision) -> Verdict {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        if mergeable == .conflicting { return .conflicting }
        if tally.failed > 0 { return .checksFailing(tally.failed) }
        if review == .changesRequested { return .changesRequested }
        if isDraft { return .draft }
        if tally.pending > 0 { return .checksRunning }
        guard tally.total > 0 || mergeable == .mergeable else { return .open }
        return review == .reviewRequired ? .reviewNeeded : .ready
    }
}
