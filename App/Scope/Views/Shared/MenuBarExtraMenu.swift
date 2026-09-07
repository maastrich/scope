import AppKit
import SwiftUI

/// Contents of the menu bar extra (spec §7, optional): the threads waiting for the user, then "Open Scope".
struct MenuBarExtraMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = model.waitingThreads
        if waiting.isEmpty {
            Text("No thread is waiting")
        } else {
            ForEach(waiting) { session in
                Button {
                    open()
                    model.reveal(thread: session.id, showDelta: false)
                } label: {
                    Text("\(session.title) — \(session.displayState.displayLabel)")
                }
            }
        }
        Divider()
        Button("Open Scope") { open() }
    }

    private func open() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) {
            openWindow(id: "main")
        }
    }
}
