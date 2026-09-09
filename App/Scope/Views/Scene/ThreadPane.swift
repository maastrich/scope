import AppKit
import SwiftUI
import ScopeCore

/// Hosts the thread's terminal view (created once by `ThreadSession`, re-parented here) and overlays the
/// non-modal `ThreadBanner` whenever the process is not alive.
struct ThreadPane: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession

    var body: some View {
        let preferences = model.config.preferences
        // Push the preferences before the host reads them; the ground below the insets uses the same palette.
        TerminalAppearance.configure(preferences)
        return ZStack(alignment: .top) {
            Color(nsColor: TerminalAppearance.background)
                .id(preferences.terminalAppearance)
            TerminalHost(session: session, fontSize: preferences.terminalFontSize,
                         appearance: preferences.terminalAppearance, cursorStyle: preferences.terminalCursorStyle)
                .id(session.id)
                .focusable(false)
            if !session.phase.isAlive {
                ThreadBanner(session: session)
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: session.phase.isAlive)
    }
}
