import Foundation

/// One tag of a card as the Graph sheet shows it: the stack and the tags merged, each said once.
public struct DisplayTag: Sendable, Hashable, Identifiable {
    /// What the chip reads (`typescript`, `github actions`).
    public var label: String
    /// The comparison key (`TagMerge.normalize`): what filters match on.
    public var key: String
    /// Came from the stack: a language, framework or tool, rather than a free keyword.
    public var isStack: Bool

    public var id: String { key }

    public init(label: String, key: String, isStack: Bool) {
        self.label = label
        self.key = key
        self.isStack = isStack
    }
}

/// The stack chips and the hashtags of a card used to say the same thing twice (`node` and `#node`). They are one
/// row now: the stack first, then the tags it does not already say, compared without case, `#`, or separators.
public enum TagMerge {
    /// Spellings of one tool that should count as one.
    static let aliases: [String: String] = [
        "nodejs": "node", "js": "javascript", "ts": "typescript", "golang": "go", "reactjs": "react", "nextjs": "next",
        "vuejs": "vue", "postgresql": "postgres", "k8s": "kubernetes", "githubactions": "github-actions",
        "dockercompose": "docker-compose", "py": "python",
    ]

    /// `#GitHub Actions`, `github_actions`, `github-actions` → `github-actions`; `Node.js` → `node`.
    public static func normalize(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasPrefix("#") { text.removeFirst() }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" || $0 == "/" }).joined(separator: "-")
        let compact = words.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
        if let alias = aliases[compact] { return alias }
        return words.replacingOccurrences(of: ".", with: "")
    }

    /// The card's one row of tags. Free tags that only restate a stack item vanish; tags that name an internal
    /// detail of the generator (`script:dev`) are dropped.
    public static func merge(stack: [String], tags: [String]) -> [DisplayTag] {
        var seen = Set<String>()
        var result: [DisplayTag] = []
        for (items, isStack) in [(stack, true), (tags, false)] {
            for raw in items {
                var label = raw.trimmingCharacters(in: .whitespaces)
                while label.hasPrefix("#") { label.removeFirst() }
                guard !label.isEmpty, !label.contains(":") else { continue }
                let key = normalize(label)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(DisplayTag(label: label.lowercased(), key: key, isStack: isStack))
            }
        }
        return result
    }

    public static func merge(_ card: RepoCard) -> [DisplayTag] {
        merge(stack: card.stack, tags: card.tags)
    }
}

/// How many tags fit one row: the rest go behind a `+N` chip. Pure so the rule is tested; the view measures.
public enum TagOverflow {
    /// - Parameters:
    ///   - widths: the width of each chip, in order.
    ///   - available: the row's width.
    ///   - spacing: the gap between two chips.
    ///   - moreWidth: the width of the `+N` chip (taken as constant whatever N).
    ///   - cap: never more than this many, even when more would fit — a row of ten chips is not read.
    /// - Returns: how many chips to show before `+N`. At least one when there is any, so a single long tag is
    ///   shown (the view lets it truncate) rather than a lone `+1`.
    public static func visibleCount(widths: [Double], available: Double, spacing: Double, moreWidth: Double, cap: Int = 6) -> Int {
        guard !widths.isEmpty else { return 0 }
        var used = 0.0
        var count = 0
        for (index, width) in widths.enumerated() {
            let isLast = index == widths.count - 1
            let next = used + (count > 0 ? spacing : 0) + width
            // Room is needed for this chip, plus the `+N` chip unless it is the last one.
            let reserve = isLast && count + 1 <= cap ? 0 : spacing + moreWidth
            guard count < cap, next + reserve <= available else { break }
            used = next
            count += 1
        }
        return max(1, count)
    }
}

/// The two lines under a card's name, and where they came from.
public struct RepoDescription: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case edited, github, manifest, ai, readme
    }

    public var text: String
    public var source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }

    /// The description a card shows. In order: what the user wrote by hand, the GitHub description, the manifest's
    /// `description`, the AI analysis's purpose, then the README's first prose sentence. The stored `purpose` of a
    /// card no driver wrote is the README's raw first paragraph — "1. Create a personal access token…" — so it is only
    /// used when it reads as prose.
    public static func choose(for card: RepoCard) -> RepoDescription? {
        let purpose = clean(card.purpose)
        if card.edited, let purpose { return RepoDescription(text: purpose, source: .edited) }
        if let github = clean(card.githubDescription) { return RepoDescription(text: github, source: .github) }
        if let manifest = clean(card.manifestDescription), says(manifest, moreThan: card.name) {
            return RepoDescription(text: manifest, source: .manifest)
        }
        if card.generatedBy == .level1 || card.promptVersion != nil, let purpose {
            return RepoDescription(text: purpose, source: .ai)
        }
        if let readme = clean(card.readmeSummary) { return RepoDescription(text: readme, source: .readme) }
        if let purpose, let sentence = Level0Generator.summary(ofReadme: purpose) {
            return RepoDescription(text: sentence, source: .readme)
        }
        return nil
    }

    /// A manifest's `description` is often its name again (`"Auth"`, `"Linger Monorepo"`): three words at least,
    /// and not the name, or it describes nothing.
    static func says(_ text: String, moreThan name: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3 && text.lowercased() != name.lowercased()
    }

    static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The small line under a card's name: `owner/repo`, never a middle-truncated path.
public enum RepoIdentity {
    /// `owner/repo` when `remote` is one or a URL that contains one; otherwise the path relative to the scope
    /// (`key`), or `nil` when that would only repeat the name.
    public static func subtitle(remote: String?, key: String, name: String) -> String? {
        if let remote, let ownerRepo = ownerRepo(remote) { return ownerRepo == name ? nil : ownerRepo }
        guard key != ".", key != name else { return nil }
        return key
    }

    /// `owner/repo` from `owner/repo`, `git@host:owner/repo.git` or `https://host/owner/repo(.git)`.
    public static func ownerRepo(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            guard let slash = text.firstIndex(of: "/") else { return nil }
            text = String(text[text.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":"), text.contains("@") {
            text = String(text[text.index(after: colon)...])
        }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }
}
