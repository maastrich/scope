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

/// The order of the scope tiles beside the current scope.
public enum ScopeTileOrder: String, Codable, Sendable, CaseIterable {
    /// Most pressing first, so what falls behind the `+N` counter is always the least urgent. Ties keep the
    /// declared order.
    case byImportance
    /// The order the scopes were declared in, which is also the order of ⌃1…⌃9.
    case declared

    public var title: String {
        switch self {
        case .byImportance: "By importance"
        case .declared: "In declared order"
        }
    }

    /// `items` in tile order. The sort is stable: equally pressing scopes never swap places.
    public func arranged<ID>(_ items: [(id: ID, activity: ScopeActivity)]) -> [ID] {
        switch self {
        case .declared:
            return items.map(\.id)
        case .byImportance:
            return items.enumerated()
                .sorted { ($0.element.activity, $0.offset) < ($1.element.activity, $1.offset) }
                .map(\.element.id)
        }
    }
}
