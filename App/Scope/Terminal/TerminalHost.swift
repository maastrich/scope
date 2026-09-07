import AppKit
import SwiftTerm
import SwiftUI

/// Re-parents the session's long-lived terminal view into a container. Never creates or destroys the
/// terminal: `ThreadSession` owns it, so tab switches keep scrollback, selection and the child process.
struct TerminalHost: NSViewRepresentable {
    let session: ThreadSession

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
        view.frame = bounds
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

    override func layout() {
        super.layout()
        hosted?.frame = bounds
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
            TerminalAppearance.applyColors(to: terminal, appearance: effectiveAppearance)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusHostedView() }
    }
}
