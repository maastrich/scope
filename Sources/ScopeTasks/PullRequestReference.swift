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

    /// A reference given on purpose (`scope task new --pr`): any shape `detect` reads, or a plain `123`.
    public static func parse(_ text: String) -> PullRequestReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed) { return number > 0 ? PullRequestReference(number: number) : nil }
        return detect(in: trimmed)
    }

    // MARK: - Start point

    /// The pull request `prompt` asks to work on — the one a task created from it checks out — or `nil`.
    ///
    /// Naming a pull request is not asking to work on it: a brief cites them as context ("follows #37", "see the
    /// research in #37"), and a task started on such a reference checks out the wrong code, or fails outright when
    /// the reference belongs to another repository. A reference counts when
    ///
    /// - the prompt is little more than the reference: `#123`, a pasted URL, "the PR #123 please" — or it opens
    ///   on a line or sentence that is ("<url>\nfix the failing test", "#6613: address the comments");
    /// - or a sentence opens on a verb of working on it and reaches the reference through a few words that only
    ///   say what of it ("review #4211", "rebase la pr <url> stp", "please fix the CI on acme/front#88").
    ///
    /// The first reference that qualifies wins; the others stay context. `detect` is still what finds them.
    public static func startPoint(in prompt: String) -> PullRequestReference? {
        let found = references(in: prompt)
        guard !found.isEmpty else { return nil }

        // Each reference becomes one opaque token, so its dots and colons never end a sentence.
        var masked = ""
        var cursor = prompt.startIndex
        for (index, item) in found.enumerated() {
            masked += prompt[cursor..<item.range.lowerBound]
            masked += " \(placeholderOpen)\(index)\(placeholderClose) "
            cursor = item.range.upperBound
        }
        masked += prompt[cursor...]

        let sentences = splitSentences(masked).map(tokens).filter { !$0.isEmpty }
        for candidate in [sentences.flatMap { $0 }, sentences.first ?? []] {
            if let index = bareReference(candidate) { return found[index].reference }
        }
        for sentence in sentences {
            if let index = referenceGoverned(in: sentence) { return found[index].reference }
        }
        return nil
    }

    private enum Token: Equatable {
        case word(String)
        case reference(Int)
    }

    /// The first reference of `tokens` when nothing else in them is more than filler.
    private static func bareReference(_ tokens: [Token]) -> Int? {
        var first: Int?
        for token in tokens {
            switch token {
            case .reference(let index): first = first ?? index
            case .word(let word): guard bareFiller.contains(word) else { return nil }
            }
        }
        return first
    }

    private static let placeholderOpen: Character = "\u{E000}"
    private static let placeholderClose: Character = "\u{E001}"

    /// The reference a sentence asks to work on: it opens on a verb (after a polite lead-in), and only words of
    /// `between` stand between the verb and the reference.
    private static func referenceGoverned(in sentence: [Token]) -> Int? {
        var position = 0
        while position < sentence.count, case .word(let word) = sentence[position], leadIns.contains(word) {
            position += 1
        }
        guard let verbLength = verbLength(at: position, in: sentence) else { return nil }
        position += verbLength
        var skipped = 0
        while position < sentence.count, skipped <= maxWordsBetween {
            switch sentence[position] {
            case .reference(let index): return index
            case .word(let word):
                guard between.contains(word) else { return nil }
                skipped += 1
                position += 1
            }
        }
        return nil
    }

    private static func verbLength(at position: Int, in sentence: [Token]) -> Int? {
        for phrase in verbs {
            guard position + phrase.count <= sentence.count else { continue }
            let matches = phrase.indices.allSatisfy { offset in
                sentence[position + offset] == .word(phrase[offset])
            }
            if matches { return phrase.count }
        }
        return nil
    }

    /// Sentences end at a newline, at `.!?;:` followed by a space, and at brackets: "(context: #37)" is an aside.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let ends = character.isNewline || "()[]—".contains(character)
                || (".!?;:".contains(character) && next.isWhitespace)
            if ends {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        sentences.append(current)
        return sentences
    }

    private static func tokens(_ sentence: String) -> [Token] {
        sentence.split(whereSeparator: \.isWhitespace).compactMap { chunk in
            if chunk.first == placeholderOpen, chunk.last == placeholderClose, let index = Int(chunk.dropFirst().dropLast()) {
                return .reference(index)
            }
            let word = chunk.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            return word.isEmpty ? nil : .word(word)
        }
    }

    /// Verbs of working on a pull request, English and French, imperative or infinitive.
    private static let verbs: [[String]] = [
        "review", "fix", "continue", "finish", "complete", "rebase", "address", "resolve", "merge", "land", "update",
        "amend", "checkout", "test", "debug", "unblock", "babysit", "ship",
        "revois", "revoir", "relis", "relire", "corrige", "corriger", "continuer", "reprends", "reprendre", "finis",
        "finir", "termine", "terminer", "finalise", "finaliser", "rebaser", "merger", "teste", "tester", "débloque",
        "débloquer",
    ].map { [$0] } + [
        ["take", "over"], ["check", "out"], ["pick", "up"], ["work", "on"], ["get", "back", "to"],
    ]

    /// What may open a sentence before its verb.
    private static let leadIns: Set<String> = [
        "please", "pls", "plz", "kindly", "can", "could", "would", "will", "you", "now", "then", "and", "also", "so",
        "ok", "okay", "go", "ahead", "i", "need", "want", "to", "we", "let's", "lets",
        "stp", "svp", "merci", "de", "peux-tu", "pourrais-tu", "tu", "peux", "pourrais", "il", "faut", "on", "doit",
        "je", "veux", "voudrais", "que",
    ]

    /// Words that may sit between the verb and the reference: they say which part of the pull request, not
    /// another subject ("fix the CI on #42" yes, "fix the bug introduced in #37" no).
    private static let between: Set<String> = [
        "the", "a", "an", "this", "that", "my", "our", "your", "pr", "prs", "pull", "request", "pull-request", "on",
        "of", "for", "ci", "build", "checks", "tests", "review", "comments", "conflicts", "branch",
        "la", "le", "les", "l'", "cette", "ce", "ma", "mon", "notre", "ta", "ton", "sur", "de", "du", "des", "d'",
        "commentaires", "branche",
    ]

    /// Everything a prompt may hold besides the reference and still be "just the reference".
    private static let bareFiller: Set<String> = between.union([
        "please", "pls", "plz", "stp", "svp", "merci", "thanks", "here", "ici", "it", "is", "voici", "voilà",
    ])

    /// Most words allowed between the verb and the reference.
    private static let maxWordsBetween = 4

    /// Every reference in `text`, in reading order. A URL wins over the shorthand or `#123` found inside it.
    private static func references(in text: String) -> [(reference: PullRequestReference, range: Range<String.Index>)] {
        var found: [(reference: PullRequestReference, range: Range<String.Index>)] = []
        func add(_ reference: PullRequestReference?, _ range: Range<String.Index>) {
            guard let reference, !found.contains(where: { $0.range.overlaps(range) }) else { return }
            found.append((reference, range))
        }
        for (groups, range) in allMatches(of: urlPattern, in: text) {
            let number = Int(groups[3]) ?? 0
            add(number > 0 ? PullRequestReference(number: number, host: groups[0].isEmpty ? nil : groups[0].lowercased(),
                                                  owner: groups[1], repo: strippingGitSuffix(groups[2])) : nil, range)
        }
        for (groups, range) in allMatches(of: shorthandPattern, in: text) {
            let number = Int(groups[2]) ?? 0
            add(number > 0 ? PullRequestReference(number: number, owner: groups[0], repo: strippingGitSuffix(groups[1])) : nil, range)
        }
        for (groups, range) in allMatches(of: barePattern, in: text) {
            let number = Int(groups[0]) ?? 0
            add(number > 0 ? PullRequestReference(number: number) : nil, range)
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
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

    /// The capture groups and the whole range of every match of `pattern` in `text`.
    private static func allMatches(of pattern: String, in text: String) -> [([String], Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let whole = Range(match.range, in: text) else { return nil }
            let groups = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return (groups, whole)
        }
    }

    private static func strippingGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
