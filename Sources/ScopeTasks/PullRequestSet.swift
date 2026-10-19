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
}
