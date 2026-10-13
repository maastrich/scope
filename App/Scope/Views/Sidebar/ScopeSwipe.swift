import AppKit
import SwiftUI

/// A two-finger horizontal swipe over the sidebar goes to the next or previous scope (Settings ▸ Sidebar).
///
/// A local monitor rather than a gesture: SwiftUI has no scroll-wheel gesture, and an `NSView` placed over the list
/// to catch the events would also catch the vertical ones the list needs. The monitor only watches — every event
/// goes on to whoever it was for — and only counts a gesture that is clearly horizontal, begins over the sidebar,
/// and is the fingers' own movement rather than the momentum after it. Over the terminal a swipe stays a scroll.
@MainActor
enum ScopeSwipe {
    private static var monitor: Any?
    private static weak var sidebar: NSView?
    private static var onSwipe: ((Int) -> Void)?
    private static var travelled: CGFloat = 0
    private static var tracking = false
    private static var fired = false

    /// Points of horizontal travel that count as a swipe.
    private static let threshold: CGFloat = 70

    static func attach(_ view: NSView, onSwipe: @escaping (Int) -> Void) {
        sidebar = view
        self.onSwipe = onSwipe
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let phase = event.phase
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let momentum = event.momentumPhase != []
            let window = event.window
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                handle(phase: phase, dx: dx, dy: dy, momentum: momentum, window: window, location: location)
            }
            return event
        }
    }

    private static func handle(phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat, momentum: Bool, window: NSWindow?, location: CGPoint) {
        guard !momentum else { return }
        if phase.contains(.began) {
            travelled = 0
            fired = false
            tracking = isOverSidebar(window: window, location: location)
        }
        guard tracking, !fired else { return }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            tracking = false
            return
        }
        // A diagonal drag is the list being scrolled, not a swipe.
        guard abs(dx) > abs(dy) * 2 else { return }
        travelled += dx
        guard abs(travelled) >= threshold else { return }
        fired = true
        // Fingers moving left bring the next scope in from the right, as pages do.
        onSwipe?(travelled < 0 ? 1 : -1)
    }

    private static func isOverSidebar(window: NSWindow?, location: CGPoint) -> Bool {
        guard let sidebar, let window, sidebar.window === window else { return false }
        return sidebar.convert(sidebar.bounds, to: nil).contains(location)
    }
}

/// Marks the sidebar's frame for `ScopeSwipe`; draws nothing.
struct ScopeSwipeArea: NSViewRepresentable {
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ScopeSwipe.attach(view, onSwipe: onSwipe)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        ScopeSwipe.attach(view, onSwipe: onSwipe)
    }
}
