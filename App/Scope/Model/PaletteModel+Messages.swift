import Foundation
import ScopeAdapters
import ScopeCore

/// The palette's ways to talk to a thread without going to it: *Ask Orchestrator…* (⇧⌘K), *Send to Thread…*, and
/// the *Ask Orchestrator: <query>* row that turns ⌘K, a sentence, ↩ into a message.
@MainActor
extension PaletteModel {
    /// The two actions, first in the Actions section.
    static func messageActions(_ model: AppModel) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let orchestrator = model.currentOrchestrator {
            items.append(PaletteItem(id: "ask-orchestrator", section: .actions, icon: "bubble.left",
                                     label: "Ask Orchestrator…", hint: model.messageTargetName(orchestrator.id),
                                     shortcut: "⇧⌘K") {
                model.searchUI.paletteMode = .compose(orchestrator.id)
                model.paletteShown = true
            })
        }
        if !model.threads.isEmpty {
            items.append(PaletteItem(id: "send-to-thread", section: .actions, icon: "arrowshape.turn.up.right",
                                     label: "Send to Thread…") {
                model.showPalette(mode: .pickThread)
            })
        }
        return items
    }

    /// *Send to Thread…*: the Go to Thread rows, each opening the message field on its thread instead.
    static func threadPickerItems(_ model: AppModel) -> [PaletteItem] {
        items(model).filter { $0.section == .threads }.compactMap { row in
            guard let id = ThreadID(rawValue: String(row.id.dropFirst("thread-".count))) else { return nil }
            return PaletteItem(id: "send-\(id.rawValue)", section: .threads, icon: row.icon, label: row.label,
                               hint: row.hint, state: row.state) {
                model.searchUI.paletteMode = .compose(id)
                model.paletteShown = true
            }
        }
    }

    /// *Ask Orchestrator: <query>*, in a section of its own under everything (`UserMessage.offersAsk`). ↩ sends the
    /// query as it is typed.
    static func askItem(_ model: AppModel, query: String, matches: Int) -> [PaletteItem] {
        guard let orchestrator = model.currentOrchestrator,
              UserMessage.offersAsk(query: query, matches: matches, hasOrchestrator: true) else { return [] }
        let id = orchestrator.id
        return [PaletteItem(id: "ask-query", section: .ask, icon: "bubble.left", label: "Ask Orchestrator: \(query)",
                            hint: model.messageTargetName(id)) {
            model.sendMessage(query, to: id)
        }]
    }
}
