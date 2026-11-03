import Foundation
import ScopeCore

/// The sidebar's arrangement held still while the list is being scrolled.
///
/// By state, a row moves to another group the moment its thread starts or stops working, and a compact task row
/// grows a second line while it is busy. Either one changes the height of the rows above whatever the user is
/// reading, and AppKit keeps the scroll offset, not the content: under the fingers, the list jumps. So while a live
/// scroll lasts — the fingers on the trackpad and the momentum after them — each row keeps the group it had when the
/// scroll began, and with it its place and its height. What a row *says* (its dot, its caption) keeps following its
/// thread; only where it sits and how tall it is wait. The rows settle into their new places once the list stops.
///
/// Keyed by whatever names a row (`RowKey`). A row that appears during the scroll has nothing held and goes where it
/// belongs.
public struct SidebarScrollHold<RowKey: Hashable & Sendable>: Sendable, Equatable {
    private var held: [RowKey: SidebarGroup]?

    public init() {}

    /// Whether a scroll is under way and the arrangement held.
    public var isHolding: Bool { held != nil }

    /// A live scroll begins: the groups the rows are in now are the ones they keep until it ends. A second begin
    /// before the end keeps the first snapshot: the list has not settled in between.
    public mutating func begin(_ groups: [RowKey: SidebarGroup]) {
        guard held == nil else { return }
        held = groups
    }

    /// The scroll is over: rows go where their state puts them.
    public mutating func end() {
        held = nil
    }

    /// The group a row is drawn in: the one it was held in, else its live one.
    public func group(of key: RowKey, live: SidebarGroup) -> SidebarGroup {
        held?[key] ?? live
    }

    /// The group a row was held in, `nil` when nothing holds it.
    public func heldGroup(of key: RowKey) -> SidebarGroup? {
        held?[key]
    }
}

extension SidebarTaskRowPolicy {
    /// Whether the row carries a second line, its group held by a scroll in progress (`SidebarScrollHold`): a held
    /// row keeps the height it had when the scroll began.
    public static func showsSecondLine(rows: SidebarRows, status: TaskStatus, held: SidebarGroup?) -> Bool {
        guard rows == .compact, let held else { return showsSecondLine(rows: rows, status: status) }
        return held == .needsYou || held == .working
    }
}
