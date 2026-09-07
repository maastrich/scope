import AppKit
import SwiftUI
import ScopeCore

/// Hosts the thread's terminal view (created once by `ThreadSession`, re-parented here) and overlays the
/// non-modal `ThreadBanner` whenever the process is not alive.
struct ThreadPane: View {
    let session: ThreadSession

    /// The terminal ground of the current appearance, so nothing else shows around the hosted view.
    private static let terminalBackground = Color(nsColor: TerminalAppearance.background)

    var body: some View {
        ZStack(alignment: .top) {
            Self.terminalBackground
            TerminalHost(session: session)
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
