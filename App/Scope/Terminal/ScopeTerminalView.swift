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
    /// A clicked link, before SwiftTerm hands it to the system; `true` when Scope showed it (a file, in the viewer).
    var onOpenLink: ((String) -> Bool)?

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if heldInput != nil, !isScopeWriting {
            heldInput?.append(contentsOf: data)
            return
        }
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    // MARK: Scope's own typing

    /// `true` while Scope writes to the child itself (`write(_:)`): those bytes are not the user's keys.
    private(set) var isScopeWriting = false
    /// The user's keys, set aside while Scope types a message around their draft (`ThreadSession.submit`).
    private var heldInput: [UInt8]?

    /// Types `text` for Scope. It still goes through `send(source:data:)`, so the thread's input tracking sees it.
    func write(_ text: String) {
        isScopeWriting = true
        defer { isScopeWriting = false }
        send(txt: text)
    }

    /// From now on, the user's keys wait until `releaseUserInput` instead of landing in the middle of Scope's typing.
    func holdUserInput() {
        if heldInput == nil { heldInput = [] }
    }

    /// Sends the keys held since `holdUserInput`, in order.
    func releaseUserInput() {
        guard let held = heldInput else { return }
        heldInput = nil
        if !held.isEmpty { send(source: self, data: held[...]) }
    }

    /// A file the agent printed opens in Scope's viewer, at the task's version of it; a web link, or a path that
    /// names nothing on disk, goes to the system as before.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if onOpenLink?(link) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    // MARK: Drops

    /// A file or folder dragged from the Finder lands on the command line as an escaped path, the way
    /// Terminal.app does it. SwiftTerm has no drop handling of its own, and nothing above the terminal may
    /// claim the drag: the window used to turn a dropped folder into a new scope.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        window?.makeFirstResponder(self)
        // Through `send(source:data:)`, like keystrokes, so the thread sees it as the user typing.
        send(source: self, data: ArraySlice(Array(ShellEscaping.droppedPaths(urls).utf8)))
        return true
    }

    private func droppedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Cursor accessories

    /// Whether the program shows the terminal cursor (DECTCEM). SwiftTerm keeps its own flag internal.
    private var cursorShown = true

    /// macOS hangs its text-cursor accessories (a small grey diamond, the caps lock and input source badges) in a
    /// window of their own at `firstRect(forCharacterRange:)`, which SwiftTerm answers with the caret's frame
    /// even while the cursor is hidden. Claude Code hides it and draws its own, so the real one sits parked in
    /// the middle of the output, and so did the diamond, over the text. No cursor on screen, no accessory.
    @objc var preferredTextAccessoryPlacement: NSTextCursorAccessoryPlacement {
        cursorShown ? .unspecified : .invisible
    }

    override func showCursor(source: Terminal) {
        super.showCursor(source: source)
        cursorVisibilityChanged(true)
    }

    override func hideCursor(source: Terminal) {
        super.hideCursor(source: source)
        cursorVisibilityChanged(false)
    }

    /// The visibility the system was last told about through `invalidateCharacterCoordinates`; `nil` once a change
    /// went unreported while unfocused, since the system then asked on its own and may hold either.
    private var reportedCursorShown: Bool? = true
    /// Bumped by every change, so only the last one of a burst reports.
    private var cursorChanges = 0

    /// A TUI hides and shows the cursor around every redraw, twenty or more times a second, and each
    /// `invalidateCharacterCoordinates` costs a `CursorUI scheduleUpdateCursorLocation` line in the unified log: the
    /// app wrote 180 000 of them a day. So the change is reported once it has stayed put for 0.15 s, only when the settled value
    /// differs from what the system last heard, and only while this view holds the keyboard — an unfocused terminal
    /// has no accessory to move, and the input context asks for the placement again when the focus comes back.
    private func cursorVisibilityChanged(_ shown: Bool) {
        guard shown != cursorShown else { return }
        cursorShown = shown
        cursorChanges &+= 1
        let change = cursorChanges
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, change == cursorChanges else { return }
            reportCursorVisibilityIfNeeded()
        }
    }

    private func reportCursorVisibilityIfNeeded() {
        guard cursorShown != reportedCursorShown else { return }
        guard let window, window.isKeyWindow, window.firstResponder === self else {
            reportedCursorShown = nil
            return
        }
        reportedCursorShown = cursorShown
        // Makes the system ask for the placement again rather than keep the accessory where it was.
        inputContext?.invalidateCharacterCoordinates()
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
