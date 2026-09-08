import Foundation
import ScopeCore

/// One repository of a scope, as the New Task sheet knows it before anything is created.
public struct RepoCandidate: Sendable, Equatable {
    /// Path relative to the scope root; `"."` for a repo scope.
    public var path: String
    /// Display name (folder name, or the scope name for `"."`).
    public var name: String
    /// `origin`, when the repository has one.
    public var remote: RemoteInfo?

    public init(path: String, name: String, remote: RemoteInfo? = nil) {
        self.path = path
        self.name = name
        self.remote = remote
    }
}

/// Reads a task request and works out what it is about: which repositories, and whether it continues
/// existing work rather than opening a branch.
///
/// Everything here is literal string matching over what the scope already knows — no model, no network —
/// so the New Task sheet can fill its fields the moment the prompt is written. The result is always shown
/// and editable: a wrong branch name is a typo, a wrong repository is a worktree in the wrong place.
public enum TaskTargets {
    /// Repositories `prompt` names, by folder name, relative path or `owner/repo` remote.
    ///
    /// Matching is case-insensitive and bounded by non-identifier characters, so `front` matches
    /// `mobsuccess-front` and `front/` but not `storefront`. Names shorter than three characters are
    /// ignored: they collide with ordinary words.
    public static func repos(namedIn prompt: String, among candidates: [RepoCandidate]) -> [String] {
        candidates.filter { candidate in
            var needles = [candidate.name, candidate.path]
            if let remote = candidate.remote {
                needles.append(remote.name)
                needles.append(remote.fullName)
            }
            return needles.contains { mentions(prompt, $0) }
        }
        .map(\.path)
    }

    /// The repository `reference` points at: the one whose `origin` it names, or — for a bare `#123` —
    /// the only candidate there is.
    public static func repo(for reference: PullRequestReference, among candidates: [RepoCandidate]) -> RepoCandidate? {
        if reference.isBare {
            // `#123` says nothing about where to look; only a single-repository scope can answer it.
            return candidates.count == 1 ? candidates[0] : nil
        }
        if let byRemote = candidates.first(where: { reference.matches($0.remote) }) { return byRemote }
        // No remote recorded yet (facts still loading, no origin): fall back to the repository's own name.
        guard let repo = reference.repo else { return nil }
        return candidates.first { $0.name.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// An existing branch `prompt` names, longest match first (`feat/auth-refresh` before `feat/auth`).
    ///
    /// Only branches that already exist can match, which is what makes this safe: an invented name is
    /// never mistaken for a request to continue someone's work.
    public static func branch(namedIn prompt: String, among branches: [String]) -> String? {
        branches
            .filter { $0.count >= 3 && mentions(prompt, $0) }
            .max { $0.count < $1.count }
    }

    /// `true` when `needle` appears in `text` delimited by characters that are not part of a name.
    ///
    /// Only letters and digits bind: `front` inside `mobsuccess-front` or `front/api` is the repository,
    /// while `front` inside `storefront` is a different word.
    static func mentions(_ text: String, _ needle: String) -> Bool {
        let needle = needle.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 3 else { return false }
        let haystack = text.lowercased()
        let target = needle.lowercased()
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: target, range: searchStart..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !isNameCharacter(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex
                || !isNameCharacter(haystack[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
