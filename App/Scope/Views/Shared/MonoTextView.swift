import AppKit
import SwiftUI

/// One attributed string for a whole diff or file plus the character ranges the caller may jump to
/// (hunk headers, lines). Built once per `version` by `MonoTextView`.
struct MonoDocument {
    var text: NSAttributedString
    /// `anchors[i]` is the range `MonoFocus(anchor: i)` scrolls to.
    var anchors: [NSRange]
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

        let textView = NSTextView(frame: .zero, textContainer: container)
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

        /// Keeps the text view at least as wide as the clip view so row tints span the visible area.
        /// Block observers are removed by the notification centre when the coordinator goes away.
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
            guard let storage = textView.textStorage, charIndex < storage.length,
                  let index = storage.attribute(.anchorIndex, at: charIndex, effectiveRange: nil) as? Int else { return false }
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
