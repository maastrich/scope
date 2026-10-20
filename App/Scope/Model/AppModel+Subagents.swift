import Foundation
import ScopeCore

extension AppModel {
    /// A sub-agent row's click: the thread selected, the Subagents card open on that sub-agent (`nil`: on the list).
    func revealSubagent(_ id: String?, of session: ThreadSession) {
        selection = .thread(session.id)
        selectedThreadID = session.id
        session.focusedSubagent = id
        inspectorShown = true
        guard isSectionAvailable(.subagents) else { return }
        setSection(.subagents, visible: true)
        setSection(.subagents, open: true)
        if let page = inspectorPlacement().page(of: .subagents) { showInspectorPage(page) }
    }
}
