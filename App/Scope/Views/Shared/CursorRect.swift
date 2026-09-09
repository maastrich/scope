import AppKit
import SwiftUI

/// Gives a view an AppKit cursor rectangle.
///
/// SwiftUI's `.pointerStyle` compiles on this deployment target but has no effect here — measured, not
/// assumed: neither `.link` on a button nor `.columnResize` on the inspector's drag handle changed the
/// pointer. `NSCursor` does work, and a cursor *rect* is the form that cannot go wrong: the window owns it
/// and resets it, so unlike `NSCursor.push()` / `.pop()` in `onHover` there is no pushed cursor left behind
/// when the view disappears from under the pointer.
extension View {
    /// The pointer takes `cursor` over this view. `nil` leaves it alone — for a control that is disabled, where
    /// a hand would promise something that does not happen.
    func cursor(_ cursor: NSCursor?) -> some View {
        overlay {
            if let cursor {
                CursorRect(cursor: cursor)
            }
        }
    }
}

private struct CursorRect: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectView {
        CursorRectView(cursor: cursor)
    }

    func updateNSView(_ view: CursorRectView, context: Context) {
        view.cursor = cursor
    }
}

final class CursorRectView: NSView {
    var cursor: NSCursor {
        didSet {
            guard cursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    /// The overlay exists only to own a cursor rect; clicks belong to whatever is underneath. Cursor rects are
    /// resolved by the window, not by hit testing, so they still apply.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
