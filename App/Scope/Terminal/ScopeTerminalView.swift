import AppKit
import ScopeCore
import SwiftTerm

/// The terminal every thread uses: SwiftTerm's view, with a scroll marker Scope draws itself.
///
/// SwiftTerm puts a standalone overlay `NSScroller` at the trailing edge. Outside a real scroll view nothing
/// ever fades it in or out, so it read as a faint strip even with nothing to scroll and never showed a knob when
/// there was. It stays, invisible: clicking and dragging along the edge still scroll, and the width it reserves
/// never changes — hiding it outright would narrow the terminal by a column the first time output overflows.
/// Over it sits the marker, placed from SwiftTerm's own numbers and drawn only while there is history to scroll
/// (never in the alternate screen of a full-screen program).
final class ScopeTerminalView: LocalProcessTerminalView {
    private let marker = ScrollMarkerView()

    /// Inset of the knob from the top, bottom and trailing edge; its thickness.
    private static let inset: CGFloat = 3
    private static let thickness: CGFloat = 5

    /// Every chunk the user types, before it reaches the child (see `ThreadSession.handleUserInput`).
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScrollMarker()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        updateScrollMarker()
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        updateScrollMarker()
    }

    /// Places or hides the marker for the current scroll state, in the terminal's own foreground colour.
    func updateScrollMarker() {
        let scroller = subviews.first { $0 is NSScroller }
        scroller?.alphaValue = 0
        if marker.superview !== self {
            addSubview(marker, positioned: .above, relativeTo: scroller)
        }
        let track = bounds.insetBy(dx: 0, dy: Self.inset)
        guard let knob = TerminalScrollMarker.knob(trackLength: Double(track.height), position: scrollPosition,
                                                   proportion: Double(scrollThumbsize), canScroll: canScroll) else {
            marker.isHidden = true
            return
        }
        let length = CGFloat(knob.length)
        let fromTop = CGFloat(knob.offset)
        let y = isFlipped ? track.minY + fromTop : track.maxY - fromTop - length
        marker.frame = NSRect(x: bounds.maxX - Self.thickness - Self.inset, y: y, width: Self.thickness, height: length)
        marker.color = nativeForegroundColor.withAlphaComponent(0.32)
        marker.isHidden = false
    }
}

/// The knob: a rounded bar that never takes a click, so the invisible scroller under it keeps its dragging.
private final class ScrollMarkerView: NSView {
    var color: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let radius = bounds.width / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}
