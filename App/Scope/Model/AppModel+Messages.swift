import Foundation
import Observation
import ScopeAdapters
import ScopeCore

/// What the chrome that sends messages needs beyond `AppModel` (which is extended, not edited): the thread whose
/// sidebar row has its reply field open, and the toast that says a message went out.
@MainActor
@Observable
final class MessageUIState {
    static let shared = MessageUIState()

    /// The thread whose sidebar row shows the inline reply field; one at a time.
    var replyingTo: ThreadID?

    struct SentNotice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let thread: ThreadID
    }

    private(set) var sent: SentNotice?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    static let sentLifetime: Duration = .seconds(4)

    func showSent(_ text: String, thread: ThreadID) {
        let notice = SentNotice(text: text, thread: thread)
        sent = notice
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.sentLifetime)
            guard !Task.isCancelled, let self, self.sent?.id == notice.id else { return }
            self.sent = nil
        }
    }

    func dismissSent() {
        expiry?.cancel()
        sent = nil
    }
}

/// Talking to a thread without switching to it: *Ask Orchestrator…* and *Send to Thread…* in the palette, the
/// sidebar's inline reply. The text is typed the way `thread.send` types it (`ThreadSession.submit`), unsigned — it is
/// the user's own — and the selection, the terminal and the keyboard stay where they were.
extension AppModel {
    var messageUI: MessageUIState { .shared }

    /// The current scope's orchestrator thread, when it has one.
    var currentOrchestrator: ThreadSession? {
        guard let scope = currentScope else { return nil }
        return UserMessage.orchestrator(of: scope.id, in: threads.map(\.record)).flatMap { session($0) }
    }

    /// ⇧⌘K and the palette's *Ask Orchestrator…*: the palette's message field, addressed to the orchestrator.
    func showAskOrchestrator() {
        guard let orchestrator = currentOrchestrator else { return }
        searchUI.paletteMode = .compose(orchestrator.id)
        paletteShown = true
    }

    /// The name the message field and the toast give `id`: "the acme orchestrator" for an orchestrator, its title
    /// otherwise.
    func messageTargetName(_ id: ThreadID) -> String {
        guard let session = session(id) else { return "the thread" }
        if session.record.resident == .orchestrator, let scope = scope(session.record.scopeID) {
            return "\(scope.name) orchestrator"
        }
        return displayTitle(for: session)
    }

    /// Sends `text` to `id` and says so in a toast with *Show*. `false` when there was nothing to send or no thread.
    @discardableResult
    func sendMessage(_ text: String, to id: ThreadID, toast: Bool = true) -> Bool {
        guard let text = UserMessage.normalized(text), let session = session(id) else { return false }
        if session.isAlive {
            session.submit(text)
        } else {
            startThenSubmit(text, to: id)
        }
        if toast { messageUI.showSent("Sent to \(messageTargetName(id))", thread: id) }
        return true
    }

    /// A stopped thread is started for the message, as `thread.send` starts a resident — here even one the user
    /// stopped: sending to it is asking for it. The text is held until the driver shows it reads input
    /// (`UserMessage.canTypeIntoStartedThread`), then typed; a thread that does not come up keeps it in the Problem
    /// Center rather than losing it.
    private func startThenSubmit(_ text: String, to id: ThreadID) {
        if let session = session(id), !session.isAlive {
            // The emulator outlives the process: a TUI killed before it could turn bracketed paste off leaves the
            // flag on, and the gate below would open on a shell still starting the driver. Off here (on the
            // emulator alone, nothing reaches a child), on again once the new driver draws its prompt.
            session.terminalView.feed(text: "\u{1b}[?2004l")
            if !isLaunching(session) { Task { await relaunch(id) } }
        }
        Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            // Past the timeout a thread still not alive is not coming up.
            while clock.now - start < UserMessage.startupTimeout * 3 {
                try? await Task.sleep(for: .milliseconds(150))
                // `conformResident` may have put a new session in its place: look it up again every time.
                guard let self, let session = self.session(id) else { return }
                if case .failed = session.phase { break }
                if case .exited = session.phase { break }
                let pasteOn = session.isAlive && session.terminalView.getTerminal().bracketedPasteMode
                if UserMessage.canTypeIntoStartedThread(alive: session.isAlive, bracketedPaste: pasteOn,
                                                        waited: clock.now - start) {
                    session.submit(text)
                    return
                }
            }
            guard let self else { return }
            let title = self.session(id).map(self.displayTitle(for:)) ?? "the thread"
            self.problems.warn("Your message never reached \(title)", detail: text,
                               scope: self.session(id)?.record.scopeID)
        }
    }

    private func isLaunching(_ session: ThreadSession) -> Bool {
        if case .launching = session.phase { return true }
        return false
    }

    /// The toast's *Show*: the thread on screen, as a click on its row would.
    func showMessageTarget(_ id: ThreadID) {
        messageUI.dismissSent()
        guard session(id) != nil else { return }
        selection = .thread(id)
        selectedThreadID = id
    }

    // MARK: Inline reply

    /// ⌥↩ on a sidebar row and its *Reply…*: opens the reply field under the row of `id`, closing any other.
    func beginReply(to id: ThreadID) {
        messageUI.replyingTo = id
    }

    func endReply() {
        messageUI.replyingTo = nil
        AppDelegate.refocusTerminal()
    }

    /// Whether the row of `session` offers *Reply…*: not while its agent is at work, where typing would land in the
    /// middle of a turn.
    func canReply(to session: ThreadSession) -> Bool {
        !session.isWorking
    }
}
