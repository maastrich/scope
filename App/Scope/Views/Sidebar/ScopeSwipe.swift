import AppKit
import ScopeCore
import SwiftUI

/// A two-finger horizontal swipe over the sidebar pages to the next or previous scope (Settings ▸ Sidebar).
///
/// A local monitor rather than a gesture: SwiftUI has no scroll-wheel gesture, and an `NSView` placed over the list
/// to catch the events would also catch the vertical ones the list needs. `PageSwipe` decides what a gesture is;
/// until it has locked the gesture as horizontal every event goes on to the list, and from then on — the momentum
/// after the release included — the sidebar keeps them, so the list does not drift under the page. Only a gesture
/// that begins over the sidebar counts: over the terminal a swipe stays a scroll.
///
/// The page follows the fingers whatever the scrolling direction is set to — it is being dragged, not scrolled — so
/// the deltas, which come with that setting applied, are turned back into the fingers' own movement first.
@MainActor
enum ScopeSwipe {
    struct Handlers {
        /// Whether there is a scope before and after the current one: the sides a page can turn to.
        var neighbours: () -> (previous: Bool, next: Bool)
        /// The page's offset while the fingers move, positive to the right.
        var onMove: (CGFloat) -> Void
        /// The release: what it means, and how fast the fingers were going (points per second) on a page this wide.
        var onEnd: (_ outcome: PageSwipe.Outcome, _ velocity: CGFloat, _ width: CGFloat) -> Void
    }

    private static var monitor: Any?
    private static weak var sidebar: NSView?
    private static var handlers: Handlers?
    private static var swipe: PageSwipe?
    private static var keepsMomentum = false

    static func attach(_ view: NSView, handlers: Handlers) {
        sidebar = view
        self.handlers = handlers
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let kept = MainActor.assumeIsolated { handle(event) }
            return kept ? nil : event
        }
    }

    /// Whether the sidebar keeps the event from the list.
    private static func handle(_ event: NSEvent) -> Bool {
        // A mouse wheel has no fingers to follow.
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] {
            let kept = keepsMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { keepsMomentum = false }
            return kept
        }
        let phase = event.phase
        if phase.contains(.began) {
            keepsMomentum = false
            swipe = nil
            guard let sidebar, let handlers, isOverSidebar(event) else { return false }
            let neighbours = handlers.neighbours()
            swipe = PageSwipe(width: sidebar.bounds.width, hasPrevious: neighbours.previous, hasNext: neighbours.next)
        }
        guard var current = swipe else { return false }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            swipe = nil
            guard current.axis == .horizontal else { return false }
            let outcome = phase.contains(.cancelled) ? .stay : current.end(at: event.timestamp)
            keepsMomentum = true
            handlers?.onEnd(outcome, current.velocity(at: event.timestamp), current.width)
            return true
        }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let axis = current.move(dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY, at: event.timestamp)
        switch axis {
        case .horizontal:
            swipe = current
            handlers?.onMove(current.offset)
            return true
        case .vertical:
            swipe = nil
            return false
        case .undecided:
            swipe = current
            return false
        }
    }

    private static func isOverSidebar(_ event: NSEvent) -> Bool {
        guard let sidebar, let window = event.window, sidebar.window === window else { return false }
        return sidebar.convert(sidebar.bounds, to: nil).contains(event.locationInWindow)
    }
}

/// Marks the sidebar's frame for `ScopeSwipe`; draws nothing.
struct ScopeSwipeArea: NSViewRepresentable {
    var handlers: ScopeSwipe.Handlers

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ScopeSwipe.attach(view, handlers: handlers)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        ScopeSwipe.attach(view, handlers: handlers)
    }
}
