import AppKit
import ScopeCore
import SwiftTerm
import SwiftUI

/// Re-parents the session's long-lived terminal view into a container. Never creates or destroys the
/// terminal: `ThreadSession` owns it, so tab switches keep scrollback, selection and the child process.
struct TerminalHost: NSViewRepresentable {
    let session: ThreadSession
    /// Read by `ThreadPane` from the preferences so a change re-runs `updateNSView` on every visible host;
    /// hidden sessions pick the new values up when their view is re-attached.
    var fontSize: Int = 13
    var appearance: TerminalAppearanceMode = .system
    var cursorStyle: TerminalCursorStyle = .steadyUnderline

    func makeNSView(context: Context) -> TerminalHostContainer {
        let container = TerminalHostContainer()
        container.onFirstLayout = { [weak session] in session?.viewDidLayout() }
        container.attach(session.terminalView)
        return container
    }

    func updateNSView(_ container: TerminalHostContainer, context: Context) {
        // SwiftUI may hand the same container to another session when `.id` is missing; keep it correct anyway.
        container.onFirstLayout = { [weak session] in session?.viewDidLayout() }
        container.attach(session.terminalView)
        container.applyPreferences()
    }

    static func dismantleNSView(_ container: TerminalHostContainer, coordinator: ()) {
        container.detach()
    }
}

/// Plain `NSView` that hosts one `TerminalView`, hands it first responder, and reports the first real layout.
final class TerminalHostContainer: NSView {
    /// Called once, the first time `layout()` runs with non-empty bounds (the child is forked with real cols × rows).
    var onFirstLayout: (@MainActor () -> Void)?
    private weak var hosted: TerminalView?
    private var didReportLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Opaque terminal background from the very first frame, so nothing light shows before the
        // hosted `TerminalView` has laid out and drawn.
        wantsLayer = true
        layer?.backgroundColor = TerminalAppearance.palette(for: effectiveAppearance).background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let hosted, let window { return window.makeFirstResponder(hosted) }
        return super.becomeFirstResponder()
    }

    func attach(_ view: TerminalView) {
        if hosted === view, view.superview === self { return }
        hosted?.removeFromSuperview()
        view.removeFromSuperview()          // may still sit in a previous container (tab switch)
        view.frame = contentFrame
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        hosted = view
        applyAppearance()          // the view may have been created or last shown under the other appearance
        didReportLayout = false
        needsLayout = true
        focusHostedView()
    }

    func detach() {
        hosted?.removeFromSuperview()
        hosted = nil
    }

    /// Makes the terminal first responder on the next run-loop turn (the window may not exist yet).
    func focusHostedView() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosted = self.hosted, let window = hosted.window else { return }
            window.makeFirstResponder(hosted)
        }
    }

    /// `true` when the window's first responder is the hosted terminal, or something inside it.
    func holdsFirstResponder(of window: NSWindow) -> Bool {
        guard let hosted else { return false }
        var view = window.firstResponder as? NSView
        while let current = view {
            if current === hosted { return true }
            view = current.superview
        }
        return false
    }

    /// The hosted view's frame: the bounds minus `TerminalAppearance.contentInsets`, never negative.
    private var contentFrame: NSRect {
        let insets = TerminalAppearance.contentInsets
        return NSRect(x: insets.left,
                      y: insets.bottom,
                      width: max(0, bounds.width - insets.left - insets.right),
                      height: max(0, bounds.height - insets.top - insets.bottom))
    }

    /// Re-applies the font, the caret and the palette after a preference change (`ThreadPane` already
    /// updated `TerminalAppearance`).
    func applyPreferences() {
        guard let terminal = hosted as? LocalProcessTerminalView else { return }
        TerminalAppearance.applyFont(to: terminal)
        TerminalAppearance.applyCursorStyle(to: terminal)
        TerminalAppearance.applyOptionKey(to: terminal)
        applyAppearance()
    }

    override func layout() {
        super.layout()
        hosted?.frame = contentFrame
        if !didReportLayout, bounds.width > 0, bounds.height > 0, hosted != nil {
            didReportLayout = true
            onFirstLayout?()
        }
    }

    /// Light/dark switch (system or app): recolour the hosted terminal and the container ground live.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = TerminalAppearance.palette(for: effectiveAppearance).background.cgColor
        if let terminal = hosted as? LocalProcessTerminalView {
            TerminalAppearance.applyFont(to: terminal)
            TerminalAppearance.applyColors(to: terminal, appearance: effectiveAppearance)
            // The scroll marker is drawn in the terminal's foreground colour, which just changed.
            (terminal as? ScopeTerminalView)?.updateScrollMarker()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusHostedView() }
    }
}
