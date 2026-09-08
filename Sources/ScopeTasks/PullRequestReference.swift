import Foundation
import ScopeCore
import ScopeGit

/// A pull request named inside a free-text prompt ("rebase https://github.com/acme/front/pull/6613").
///
/// Detection is deliberately literal — a regex over the shapes GitHub itself produces — so that a task
/// created from such a prompt checks the pull request's head out instead of branching from the default
/// branch. `TaskProposer` is never asked in that case: the branch is not a naming decision, it exists.
public struct PullRequestReference: Sendable, Equatable, Hashable {
    /// The pull request number.
    public var number: Int
    /// Host of the URL the reference came from (`github.com`, an Enterprise host); `nil` for `#123`.
    public var host: String?
    /// Owner from the URL or from `owner/repo#123`; `nil` for a bare `#123`.
    public var owner: String?
    /// Repository name from the URL or from `owner/repo#123`; `nil` for a bare `#123`.
    public var repo: String?

    public init(number: Int, host: String? = nil, owner: String? = nil, repo: String? = nil) {
        self.number = number
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    /// `#123`, with no repository to disambiguate it. Only usable when a single repository is in play.
    public var isBare: Bool { owner == nil || repo == nil }

    /// `owner/repo`, when the reference carries one.
    public var fullName: String? {
        guard let owner, let repo else { return nil }
        return "\(owner)/\(repo)"
    }

    /// `owner/repo#123`, or `#123`.
    public var label: String { "\(fullName ?? "")#\(number)" }

    /// The first pull request named in `text`, in the shapes GitHub produces:
    ///
    /// - `https://github.com/owner/repo/pull/123`, with or without a scheme, a `www.` prefix, a trailing
    ///   segment (`/files`, `/commits/<sha>`), a query or a fragment; any host, so Enterprise URLs work.
    /// - `owner/repo#123`
    /// - `#123` (bare, `isBare`)
    ///
    /// `/issues/123` and `/discussions/123` never match: a task on an issue has no branch to check out.
    public static func detect(in text: String) -> PullRequestReference? {
        if let match = firstMatch(of: urlPattern, in: text) {
            let number = Int(match[3]) ?? 0
            if number > 0 {
                return PullRequestReference(
                    number: number,
                    host: match[0].isEmpty ? nil : match[0].lowercased(),
                    owner: match[1], repo: strippingGitSuffix(match[2])
                )
            }
        }
        if let match = firstMatch(of: shorthandPattern, in: text), let number = Int(match[2]), number > 0 {
            return PullRequestReference(number: number, owner: match[0], repo: strippingGitSuffix(match[1]))
        }
        if let match = firstMatch(of: barePattern, in: text), let number = Int(match[0]), number > 0 {
            return PullRequestReference(number: number)
        }
        return nil
    }

    /// `true` when this reference names the repository `remote` points at.
    ///
    /// A bare `#123` matches any repository — the caller must only use it when one repository is in play.
    /// The host is compared when both sides have one, so a `github.com` URL never resolves against a GitLab
    /// remote; the owner and the name are compared case-insensitively, as GitHub does.
    public func matches(_ remote: RemoteInfo?) -> Bool {
        guard let remote else { return false }
        guard let repo, let owner else { return true }
        guard repo.caseInsensitiveCompare(remote.name) == .orderedSame else { return false }
        if let remoteOwner = remote.owner, owner.caseInsensitiveCompare(remoteOwner) != .orderedSame { return false }
        if let host, let remoteHost = remote.host, host.caseInsensitiveCompare(remoteHost) != .orderedSame { return false }
        return true
    }

    // MARK: - Patterns

    // [host] / owner / repo / pull / number
    private static let urlPattern =
        #"(?:https?://)?(?:www\.)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pulls?/(\d+)"#
    // owner / repo # number
    private static let shorthandPattern = #"(?<![A-Za-z0-9._/-])([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#(\d+)"#
    // # number
    private static let barePattern = #"(?<![A-Za-z0-9._-])#(\d+)(?![A-Za-z0-9._-])"#

    /// The capture groups of the first match of `pattern` in `text`, or `nil`.
    private static func firstMatch(of pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    private static func strippingGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
