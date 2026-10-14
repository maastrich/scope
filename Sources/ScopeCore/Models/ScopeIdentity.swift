import Foundation

/// The colour of a scope's tile. A fixed set rather than a free colour: each one is checked once against the
/// sidebar ground in both appearances, which a colour picker cannot promise. None of them is a state colour —
/// the waiting orange and the failure red stay the loudest hues in the sidebar.
public enum ScopeTint: String, Codable, Sendable, CaseIterable {
    case violet, teal, gold, sky, pink, slate, moss, clay

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The tint a scope gets until one is chosen: stable for a slug, so a scope keeps its colour across launches
    /// and machines without anything being stored.
    public static func derived(from slug: String) -> ScopeTint {
        let sum = slug.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
        return allCases[sum % allCases.count]
    }
}

extension ScopeDeclaration {
    /// The colour of the tile: the chosen one, else the one derived from the slug.
    public var resolvedTint: ScopeTint { tint ?? .derived(from: slug) }

    /// The image file the tile shows in an appearance: the dark one when there is one, else the one image.
    public func logo(dark: Bool) -> String? { dark ? logoDark ?? logo : logo }

    /// What the tile shows without a logo: the chosen icon (an emoji or a few letters), else the first letter of
    /// the name, skipping the `@` of an organisation folder.
    public var monogram: String {
        if let icon = icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty { return String(icon.prefix(2)) }
        let letter = name.first { $0.isLetter || $0.isNumber }
        return letter.map { String($0).uppercased() } ?? "?"
    }
}

/// What is going on in a scope, as one fact: the most pressing thing among its threads. It is what the scope's
/// tile carries as a mark, and what orders the tiles.
public enum ScopeActivity: Int, Sendable, CaseIterable, Comparable {
    /// A thread asks a question or a permission.
    case waiting
    /// A turn stopped on an error.
    case failed
    /// A turn ended and its result was not looked at.
    case unread
    /// Agents are working and ask nothing.
    case working
    /// Nothing is happening.
    case quiet
    /// The scope's folder is gone.
    case missing

    public init(threads: some Sequence<ThreadState>, missing: Bool = false) {
        if missing {
            self = .missing
            return
        }
        var found = ScopeActivity.quiet
        for state in threads {
            let activity: ScopeActivity = switch state {
            case .waiting: .waiting
            case .failed: .failed
            case .done: .unread
            case .running: .working
            case .idle, .exited: .quiet
            }
            found = min(found, activity)
        }
        self = found
    }

    public static func < (lhs: ScopeActivity, rhs: ScopeActivity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `a thread needs you`, `quiet`: the tile's tooltip and the scope menu.
    public var label: String {
        switch self {
        case .waiting: "a thread needs you"
        case .failed: "a thread stopped on an error"
        case .unread: "a result is not read yet"
        case .working: "agents are working"
        case .quiet: "quiet"
        case .missing: "folder missing"
        }
    }
}

/// Which scope tiles keep their place beside the current scope when they do not all fit.
///
/// The tiles are always *shown* in the order of the ring (`ScopeCycle.rotated`) — the first is where a swipe to the
/// next scope goes, the last where a swipe to the previous one does — so the header reads like the swipe. What
/// this decides is only which of them fall behind the `+N` counter.
public enum ScopeTileOrder: String, Codable, Sendable, CaseIterable {
    /// The most pressing scopes keep a tile, so what falls behind the `+N` counter is the least urgent. Ties go
    /// to the scope nearer in the ring.
    case byImportance
    /// The scopes nearest in the ring keep a tile; the farthest go behind the counter.
    case declared

    public var title: String {
        switch self {
        case .byImportance: "Most urgent"
        case .declared: "Nearest"
        }
    }

    /// `ring` — the other scopes in ring order — split into the `visible` that keep a tile and the rest, both
    /// still in ring order.
    ///
    /// The two swipe destinations, the first and the last of the ring, always keep theirs while there is room: a
    /// tile row whose ends were not where a swipe goes would contradict the gesture it is there to explain. This
    /// order only picks among the others.
    public func split<ID>(_ ring: [(id: ID, activity: ScopeActivity)], visible: Int) -> (shown: [ID], hidden: [ID]) {
        let count = min(max(visible, 0), ring.count)
        var kept = Set<Int>()
        if count >= 1 { kept.insert(0) }
        if count >= 2 { kept.insert(ring.count - 1) }
        let candidates = ring.indices.filter { !kept.contains($0) }
        let ranked: [Int]
        switch self {
        case .declared:
            ranked = candidates
        case .byImportance:
            // Stable: equally pressing scopes keep the ring's order between them.
            ranked = candidates.sorted { (ring[$0].activity, $0) < (ring[$1].activity, $1) }
        }
        kept.formUnion(ranked.prefix(count - kept.count))
        let shown = ring.indices.filter(kept.contains).map { ring[$0].id }
        let hidden = ring.indices.filter { !kept.contains($0) }.map { ring[$0].id }
        return (shown, hidden)
    }
}
