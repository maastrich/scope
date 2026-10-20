import Foundation

/// The two pages of a task's inspector column: what is happening (Overview) and what you go and look up (Details).
///
/// A column holding every card at once crushed the one list that matters while an agent works: a task showed twelve
/// headers, half of them saying *none yet*, and the changes were cut short. Overview now holds the cards that have
/// something to say — a plan, changes, a pull request, a running sub-agent or background command, an artifact — in a
/// fixed order; Details holds the reference cards (where the task runs, what the agent was given, the base
/// checkout) and every event card while it is empty. Without a task there is a single page: the base checkout.
public enum InspectorPage: String, Codable, Sendable, CaseIterable, Hashable {
    case overview, details

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .details: "Details"
        }
    }
}

extension InspectorSection {
    /// The cards that come up to Overview when they have something to say, in the order Overview shows them: what
    /// the agent means to do, what changed, what shipped, then what runs beside it, then what it produced. Fixed, so
    /// a card that comes up always lands in the same place.
    public static let eventCards: [InspectorSection] = [.plan, .delta, .pullRequest, .subagents, .background, .artifacts]

    /// Whether the card comes up to Overview by itself when it has content.
    public var isEventCard: Bool { Self.eventCards.contains(self) }
}

/// Which card goes on which page, from what each card has to say right now. Pure: the app passes the facts and the
/// time, so the rules are tested here rather than eyeballed.
///
/// A card is on Overview when it is pinned there, when it is an event card with content, when it lost its content
/// less than `linger` ago (so a background command that just finished is seen finished, *finished 2 min ago*,
/// before it goes), or when it is `retained` — on Overview and open, which is how the user says they are reading
/// it: it stays until they fold it or change task. Everything else visible is on Details.
public enum InspectorPlacement {
    /// How long a card that went quiet stays on Overview with its final state.
    public static let linger: TimeInterval = 3 * 60

    /// What one event card says now: whether it has content, and when what it showed last ended (the background
    /// command that exited, the sub-agent that answered) — the start of its linger. Domain times, not the moment
    /// the app noticed, so a relaunch or a task switch does not restart the clock.
    public struct Signal: Sendable, Equatable {
        public var hasContent: Bool
        public var endedAt: Date?

        public init(hasContent: Bool, endedAt: Date? = nil) {
            self.hasContent = hasContent
            self.endedAt = endedAt
        }

        public static let empty = Signal(hasContent: false)
        public static let content = Signal(hasContent: true)
    }

    public struct Result: Sendable, Equatable {
        /// The cards of Overview, in its order.
        public var overview: [InspectorSection]
        /// The cards of Details, in its order.
        public var details: [InspectorSection]
        /// Cards on Overview only because they are lingering.
        public var lingering: Set<InspectorSection>
        /// When the placement changes by itself: the first linger to run out. `nil` when nothing lingers.
        public var nextChange: Date?

        public init(overview: [InspectorSection], details: [InspectorSection], lingering: Set<InspectorSection> = [],
                    nextChange: Date? = nil) {
            self.overview = overview
            self.details = details
            self.lingering = lingering
            self.nextChange = nextChange
        }

        public func cards(on page: InspectorPage) -> [InspectorSection] {
            page == .overview ? overview : details
        }

        /// The page a card is on; `nil` for a hidden one.
        public func page(of section: InspectorSection) -> InspectorPage? {
            if overview.contains(section) { return .overview }
            if details.contains(section) { return .details }
            return nil
        }
    }

    /// Overview's order: Environment first when it is pinned (it says where everything below runs), the event cards,
    /// then any other card pinned there in the column's order.
    public static let overviewOrder: [InspectorSection] =
        [.environment] + InspectorSection.eventCards
        + InspectorSection.allCases.filter { $0 != .environment && !$0.isEventCard }

    /// Details' order: about the task (Environment, Context, Connectors), the event cards with nothing to say yet,
    /// then the base checkout.
    public static let detailsOrder: [InspectorSection] =
        [.environment, .context, .connectors] + InspectorSection.eventCards + [.base, .files, .search, .history]

    /// Where every visible card of `sections` goes. Without a task there is one page — the base checkout, as before
    /// the split — returned as Overview with Details empty: splitting it would leave Overview with nothing.
    public static func place(sections: InspectorSections, hasTask: Bool, signals: [InspectorSection: Signal],
                             retained: Set<InspectorSection> = [], now: Date) -> Result {
        let visible = Set(sections.visible)
        guard hasTask else {
            return Result(overview: sections.visible.filter { !$0.needsTask }, details: [])
        }
        var up: Set<InspectorSection> = []
        var lingering: Set<InspectorSection> = []
        var nextChange: Date?
        for section in visible {
            if sections.isPinned(section) || retained.contains(section) {
                up.insert(section)
                continue
            }
            guard section.isEventCard else { continue }
            let signal = signals[section] ?? .empty
            if signal.hasContent {
                up.insert(section)
            } else if let ended = signal.endedAt {
                let expiry = ended.addingTimeInterval(linger)
                if expiry > now {
                    up.insert(section)
                    lingering.insert(section)
                    nextChange = min(nextChange ?? expiry, expiry)
                }
            }
        }
        return Result(overview: overviewOrder.filter { up.contains($0) },
                      details: detailsOrder.filter { visible.contains($0) && !up.contains($0) },
                      lingering: lingering, nextChange: nextChange)
    }

    /// The cards kept on Overview however quiet they get, after the placement changed: those already kept that are
    /// still open, and every Overview card that is open now. Folding a card lets it go; a task switch starts empty.
    public static func retained(previous: Set<InspectorSection>, overview: [InspectorSection],
                                open: Set<InspectorSection>) -> Set<InspectorSection> {
        previous.intersection(open).union(Set(overview).intersection(open))
    }

    /// The cards that went from Overview down to Details between two placements: what the Details button's dot says
    /// happened while the user was looking elsewhere.
    public static func demoted(from before: Result, to after: Result) -> Set<InspectorSection> {
        Set(before.overview).intersection(after.details)
    }
}
