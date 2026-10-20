import AppKit
import ScopeCore
import SwiftUI

/// `TerminalHost` for a task shell: re-parents the session's long-lived terminal view into a
/// `TerminalHostContainer`, so a tab switch keeps scrollback, selection and the process.
struct TaskShellHost: NSViewRepresentable {
    let session: TaskShellSession
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
        container.onFirstLayout = { [weak session] in session?.viewDidLayout() }
        container.attach(session.terminalView)
        container.applyPreferences()
    }

    static func dismantleNSView(_ container: TerminalHostContainer, coordinator: ()) {
        container.detach()
    }
}
