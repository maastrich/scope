import AppKit
import SwiftUI

/// One attributed string for a whole diff or file plus the character ranges the caller may jump to
/// (hunk headers, lines). Built once per `version` by `MonoTextView`.
struct MonoDocument {
    var text: NSAttributedString
    /// `anchors[i]` is the range `MonoFocus(anchor: i)` scrolls to.
    var anchors: [NSRange]
    /// Range of each line that can be picked from the gutter, by the key its `.lineKey` attribute carries.
    var lines: [Int: NSRange] = [:]
}

/// A scroll request: which anchor, where on screen, and a token so repeating the same jump still scrolls.
struct MonoFocus: Equatable {
    enum Placement: Equatable { case top, center }
    var anchor: Int
    var placement: Placement = .top
    var token: Int = 0
}

/// Row-wide tints: added / removed / hunk / highlighted lines painted from the left edge to the right
/// edge of the visible area, whatever the line length (`.backgroundColor` only covers the glyphs).
extension NSAttributedString.Key {
    static let rowBackground = NSAttributedString.Key("scope.rowBackground")
    /// `Int` on a hunk header line: clicking it calls `MonoTextView.onAnchorClick`.
    static let anchorIndex = NSAttributedString.Key("scope.anchorIndex")
    /// `Int` on a line the gutter can select (a diff line): the key of `MonoDocument.lines`.
    static let lineKey = NSAttributedString.Key("scope.lineKey")
    /// `String` on a comment row: clicking it calls `MonoTextView.onCommentClick` with it.
    static let commentID = NSAttributedString.Key("scope.commentID")
}

/// Colours and font shared by the diff and the Base viewer. Asset colours with a fallback so the view
/// renders before the colour sets land.
@MainActor
enum MonoStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let signFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let lineHeight: CGFloat = 18

    static func asset(_ name: String, fallback: NSColor) -> NSColor {
        NSColor(named: name) ?? fallback
    }

    static var diffAdded: NSColor { asset("DiffAdded", fallback: NSColor.systemGreen.withAlphaComponent(0.14)) }
    static var diffRemoved: NSColor { asset("DiffRemoved", fallback: NSColor.systemRed.withAlphaComponent(0.12)) }
    static var diffAddedSign: NSColor { asset("DiffAddedSign", fallback: .systemGreen) }
    static var diffRemovedSign: NSColor { asset("DiffRemovedSign", fallback: .systemRed) }
    static var hunkText: NSColor { asset("HunkText", fallback: NSColor(red: 0.235, green: 0.435, blue: 0.690, alpha: 1)) }
    static var hunkBackground: NSColor { asset("HunkBackground", fallback: NSColor.controlAccentColor.withAlphaComponent(0.08)) }
    static var focusedHunkBackground: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.18) }
    static var lineHighlight: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.16) }
    static var termHighlight: NSColor { NSColor.findHighlightColor.withAlphaComponent(0.55) }
    static var gutter: NSColor { .secondaryLabelColor }
    static var text: NSColor { .labelColor }
    static var muted: NSColor { .tertiaryLabelColor }

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.tabStops = []
        style.defaultTabInterval = 4 * ("0" as NSString).size(withAttributes: [.font: font]).width
        return style
    }

    static func base(color: NSColor = text, font: NSFont = font) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// Right-aligned number in `width` cells (blank when `nil`).
    static func gutterText(_ number: Int?, width: Int) -> String {
        let digits = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, width - digits.count)) + digits
    }
}

/// A read-only, non-wrapping `NSTextView` in an `NSScrollView` (both axes). The text is rebuilt only
/// when `version` changes, the view scrolls to the top when `identity` changes, and `focus` scrolls to
/// an anchor of the document.
struct MonoTextView: NSViewRepresentable {
    /// Scroll to the top when this changes (a different file).
    var identity: AnyHashable
    /// Rebuild the text when this changes (folds, highlights, focus tint).
    var version: AnyHashable
    var build: () -> MonoDocument
    var focus: MonoFocus?
    var onAnchorClick: ((Int) -> Void)?
    /// Width in points of the line-number gutter; the gutter comment affordance lives there. 0 turns it off.
    var gutterWidth: CGFloat = 0
    /// A click or a drag in the gutter picked the lines whose keys are in the range; the rect covers them, in the
    /// coordinates of the view passed along (to hang a popover on).
    var onGutterSelection: ((ClosedRange<Int>, NSRect, NSView) -> Void)?
    /// A comment row was clicked.
    var onCommentClick: ((String, NSRect, NSView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = RowBackgroundLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = GutterTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.font = MonoStyle.font
        textView.textColor = MonoStyle.text
        textView.linkTextAttributes = [:]
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.observeClipView()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onAnchorClick = onAnchorClick
        coordinator.onCommentClick = onCommentClick
        if let textView = coordinator.textView as? GutterTextView {
            textView.gutterWidth = gutterWidth
            if let onGutterSelection {
                textView.onGutterSelection = { [weak textView] keys, rect in
                    guard let textView else { return }
                    onGutterSelection(keys, rect, textView)
                }
            } else {
                textView.onGutterSelection = nil
            }
        }
        let identityChanged = coordinator.identity != identity
        if coordinator.version != version || identityChanged {
            coordinator.version = version
            coordinator.identity = identity
            coordinator.setDocument(build())
            if identityChanged {
                coordinator.scrollToTop()
                coordinator.lastFocus = nil
            }
        }
        if let focus, focus != coordinator.lastFocus {
            coordinator.lastFocus = focus
            coordinator.scroll(to: focus)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var identity: AnyHashable?
        var version: AnyHashable?
        var lastFocus: MonoFocus?
        var anchors: [NSRange] = []
        var onAnchorClick: ((Int) -> Void)?
        var onCommentClick: ((String, NSRect, NSView) -> Void)?

        /// Keeps the text view at least as wide as the clip view so row tints span the visible area.
        /// The selector observer is dropped by the notification centre when the coordinator goes away
        /// (a block observer would need its token stored and removed by hand).
        func observeClipView() {
            guard let scrollView else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewChanged),
                                                   name: NSView.frameDidChangeNotification, object: scrollView.contentView)
            fitToClipView()
        }

        @objc private func clipViewChanged(_ note: Notification) {
            fitToClipView()
        }

        private func fitToClipView() {
            guard let scrollView, let textView else { return }
            let size = scrollView.contentView.bounds.size
            textView.minSize = size
            textView.sizeToFit()
        }

        func setDocument(_ document: MonoDocument) {
            guard let textView, let storage = textView.textStorage else { return }
            anchors = document.anchors
            (textView as? GutterTextView)?.lineRanges = document.lines
            let selected = textView.selectedRange()
            storage.beginEditing()
            storage.setAttributedString(document.text)
            storage.endEditing()
            if selected.location + selected.length <= storage.length {
                textView.setSelectedRange(selected)
            }
            fitToClipView()
        }

        func scrollToTop() {
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func scroll(to focus: MonoFocus) {
            guard let scrollView, let textView, let layout = textView.layoutManager, let container = textView.textContainer,
                  anchors.indices.contains(focus.anchor) else { return }
            let range = anchors[focus.anchor]
            layout.ensureLayout(forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerInset.height
            let clip = scrollView.contentView
            let visible = clip.bounds.height
            var y: CGFloat
            switch focus.placement {
            case .top: y = rect.minY - 6
            case .center: y = rect.midY - visible / 2
            }
            y = min(max(0, y), max(0, textView.frame.height - visible))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let storage = textView.textStorage, charIndex < storage.length else { return false }
            if let id = storage.attribute(.commentID, at: charIndex, effectiveRange: nil) as? String,
               let gutter = textView as? GutterTextView {
                onCommentClick?(id, gutter.lineRect(containing: charIndex), gutter)
                return true
            }
            guard let index = storage.attribute(.anchorIndex, at: charIndex, effectiveRange: nil) as? Int else { return false }
            onAnchorClick?(index)
            return true
        }
    }
}

/// Paints `.rowBackground` across the whole line fragment, from the left edge of the text view to the
/// right edge of the (at least clip-wide) text view.
final class RowBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // The two `main actor-isolated property … from a nonisolated context` warnings below are known. AppKit
        // draws on the main thread, so the reads are safe, but the override cannot be `@MainActor` (the
        // superclass method is not) and `MainActor.assumeIsolated` cannot take this nonisolated `self` with it.
        // Silencing them properly means caching the width on this layout manager and pushing it from the view.
        if let storage = textStorage, let textView = textContainers.first?.textView {
            let width = max(textView.bounds.width, textView.frame.width)
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
                let chars = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                guard chars.location < storage.length,
                      let color = storage.attribute(.rowBackground, at: chars.location, effectiveRange: nil) as? NSColor
                else { return }
                color.setFill()
                NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// The text view of `MonoTextView`, with the diff's comment affordance: a "+" in the gutter under the pointer,
/// and a click or a drag down the gutter picking one line or a range. The text itself stays selectable as before;
/// only presses that start in the gutter are taken.
final class GutterTextView: NSTextView {
    var gutterWidth: CGFloat = 0
    var onGutterSelection: ((ClosedRange<Int>, NSRect) -> Void)?
    var lineRanges: [Int: NSRange] = [:]

    private var hoverKey: Int? {
        didSet { if hoverKey != oldValue { needsDisplay = true } }
    }
    private var drag: (start: Int, end: Int)? {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    private var isActive: Bool { onGutterSelection != nil && gutterWidth > 0 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverKey = isActive && point.x < gutterWidth ? lineKey(at: point) : nil
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverKey = nil
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isActive, point.x < gutterWidth, let key = lineKey(at: point) {
            drag = (key, key)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return super.mouseDragged(with: event) }
        if let key = lineKey(at: convert(event.locationInWindow, from: nil)) {
            current.end = key
            drag = current
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return super.mouseUp(with: event) }
        drag = nil
        let keys = min(current.start, current.end)...max(current.start, current.end)
        onGutterSelection?(keys, lineRect(keys))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let current = drag {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            lineRect(min(current.start, current.end)...max(current.start, current.end)).fill()
        } else if let key = hoverKey {
            let line = lineRect(key...key)
            let badge = NSRect(x: 2, y: line.midY - 7, width: 14, height: 14)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            let plus = NSAttributedString(string: "+", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = plus.size()
            plus.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
    }

    /// The key of the gutter line at `point`'s height, `nil` over a hunk header, a comment row or empty space.
    func lineKey(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: 1, y: point.y - textContainerInset.height)
        let glyph = layout.glyphIndex(for: local, in: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= fragment.minY, local.y < fragment.maxY else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.lineKey, at: character, effectiveRange: nil) as? Int
    }

    /// Full-width rect of the lines whose keys are in `keys`, in view coordinates.
    func lineRect(_ keys: ClosedRange<Int>) -> NSRect {
        let ranges = keys.compactMap { lineRanges[$0] }
        guard let first = ranges.min(by: { $0.location < $1.location }),
              let last = ranges.max(by: { NSMaxRange($0) < NSMaxRange($1) }) else { return .zero }
        return rect(forCharacters: NSRange(location: first.location, length: max(1, NSMaxRange(last) - first.location - 1)))
    }

    /// Full-width rect of the line holding `charIndex`.
    func lineRect(containing charIndex: Int) -> NSRect {
        rect(forCharacters: NSRange(location: charIndex, length: 1))
    }

    private func rect(forCharacters range: NSRange) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textContainerInset.height
        rect.origin.x = 0
        rect.size.width = max(bounds.width, frame.width)
        return rect
    }
}
