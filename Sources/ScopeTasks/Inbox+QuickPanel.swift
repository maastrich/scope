import Foundation

extension Inbox {
    /// The order the quick panel's Inbox tab draws: what blocks an agent first — questions and permissions, newest
    /// first — then everything else, newest first. The sheet groups by scope; the panel is small and opened to
    /// answer, so the answer wanted sits on top whatever scope asks it.
    public static func urgentFirst(_ items: [Item]) -> [Item] {
        let urgent = items.filter(\.kind.isBlocking).sorted(by: order)
        let rest = items.filter { !$0.kind.isBlocking }.sorted(by: order)
        return urgent + rest
    }
}

extension Inbox.Kind {
    /// The agent cannot go on without the owner.
    public var isBlocking: Bool {
        self == .question || self == .permission
    }
}
