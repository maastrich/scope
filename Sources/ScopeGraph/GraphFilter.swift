import Foundation

/// The filter of the Graph sheet, shared by its three views: a text, plus the domain and tag chips picked.
///
/// Chips of one kind widen (Front *or* Back), the two kinds narrow each other (Front *and* react), and the text
/// narrows both — the way the filters of a Linear or GitHub list combine.
public struct GraphFilter: Sendable, Equatable {
    public var text: String
    /// Normalized tag keys (`TagMerge.normalize`).
    public var tags: Set<String>
    public var domains: Set<RepoDomain>

    public init(text: String = "", tags: Set<String> = [], domains: Set<RepoDomain> = []) {
        self.text = text
        self.tags = tags
        self.domains = domains
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && tags.isEmpty && domains.isEmpty
    }

    /// Whether the repo at `key` passes. `tags` and `domain` are what the sheet shows for the card, passed in so
    /// they are worked out once per card rather than once per keystroke.
    public func matches(key: String, card: RepoCard, tags cardTags: [DisplayTag], domain: RepoDomain, description: String?) -> Bool {
        if !domains.isEmpty, !domains.contains(domain) { return false }
        if !tags.isEmpty {
            let keys = Set(cardTags.map(\.key))
            guard tags.contains(where: keys.contains) else { return false }
        }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([key, card.name, card.remote ?? "", description ?? "", domain.title] + cardTags.map(\.label))
            .joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Picks `tag` when it is not, drops it when it is.
    public mutating func toggle(tag key: String) {
        if tags.remove(key) == nil { tags.insert(key) }
    }

    public mutating func toggle(domain: RepoDomain) {
        if domains.remove(domain) == nil { domains.insert(domain) }
    }
}

/// How many cards carry each tag and domain: the chips of the filter bar, most used first.
public enum GraphFacets {
    public struct Count: Sendable, Equatable, Hashable {
        public var key: String
        public var label: String
        public var count: Int
    }

    /// Tag chips, most frequent first, then by label. A tag only one repo has is not a useful filter and is left
    /// out unless `includeSingles`.
    public static func tags(_ cards: [[DisplayTag]], includeSingles: Bool = false) -> [Count] {
        var counts: [String: Count] = [:]
        for tags in cards {
            for tag in Set(tags) {
                counts[tag.key, default: Count(key: tag.key, label: tag.label, count: 0)].count += 1
            }
        }
        return counts.values.filter { includeSingles || $0.count > 1 }
            .sorted { ($1.count, $0.label) < ($0.count, $1.label) }
    }

    /// Domains present, in `RepoDomain` order.
    public static func domains(_ domains: [RepoDomain]) -> [(domain: RepoDomain, count: Int)] {
        var counts: [RepoDomain: Int] = [:]
        for domain in domains { counts[domain, default: 0] += 1 }
        return counts.keys.sorted().map { ($0, counts[$0]!) }
    }
}
