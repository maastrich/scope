import AppKit
import SwiftUI

/// Gives a view a pointer shape while the pointer is over it.
///
/// Two earlier attempts are worth knowing about, because both compile and neither works here:
///
/// - SwiftUI's `.pointerStyle` does nothing in this app. Measured with a screenshot of the pointer, not
///   assumed: neither `.link` over a button nor `.columnResize` over the inspector's drag handle changed it.
/// - An AppKit cursor rect (`addCursorRect`) does nothing either: SwiftUI runs its own tracking areas and
///   never asks a hosted `NSView` to reset its cursor rects, so the rect is never installed.
///
/// What does work is the hover reporting SwiftUI already drives everywhere else in this app.
/// `onContinuousHover` fires on every move inside the view, and `NSCursor.set()` is transient — the system
/// puts the arrow back as soon as the pointer leaves — so setting it on each move holds the shape without any
/// push/pop bookkeeping, and nothing can stay stuck when the view disappears from under the pointer.
extension View {
    /// The pointer takes `cursor` over this view. `nil` leaves it alone — for a control that is disabled, where
    /// a shape would promise something that does not happen.
    func cursor(_ cursor: NSCursor?) -> some View {
        onContinuousHover { phase in
            guard let cursor else { return }
            switch phase {
            case .active: cursor.set()
            case .ended: NSCursor.arrow.set()
            @unknown default: NSCursor.arrow.set()
            }
        }
    }
}
