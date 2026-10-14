import Foundation

/// The ring the scopes form: the order a swipe, ⌥⌘→ and the header tiles all follow.
///
/// The scopes are a loop, not a shelf — paging past the last one comes back to the first, in either direction —
/// so the order has to be one that never changes under the user's feet: the declared order, the order of ⌃1…⌃9.
/// An order that followed what is happening in each scope would renumber itself as soon as a thread finished, and
/// a loop whose steps move is a loop that never visits every scope.
public enum ScopeCycle {
    /// The item `delta` places from `current` around the ring, or `nil` when there is no second item to reach.
    public static func neighbour<ID: Equatable>(of current: ID, in items: [ID], delta: Int) -> ID? {
        guard items.count > 1, let index = items.firstIndex(of: current) else { return nil }
        let count = items.count
        return items[((index + delta) % count + count) % count]
    }

    /// The other items in the order the ring walks them, starting one step after `current`: the first is where a
    /// swipe to the next goes, the last is where a swipe to the previous one does.
    public static func rotated<ID: Equatable>(_ items: [ID], after current: ID) -> [ID] {
        guard let index = items.firstIndex(of: current) else { return items }
        return Array(items[(index + 1)...] + items[..<index])
    }

    /// Whether stepping from `current` to `target` walks the ring forwards — the side the arriving scope slides in
    /// from. The shorter way round decides, so the last scope to the first is a step forwards, not a run back
    /// through the whole list.
    public static func isForward<ID: Equatable>(from current: ID, to target: ID, in items: [ID]) -> Bool {
        guard let from = items.firstIndex(of: current), let to = items.firstIndex(of: target), items.count > 1 else {
            return true
        }
        let count = items.count
        let forwardSteps = ((to - from) % count + count) % count
        return forwardSteps * 2 <= count
    }
}
