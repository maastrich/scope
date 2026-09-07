import AppKit
import SwiftTerm

/// SwiftTerm 1.20.0 declares `LocalProcessTerminalViewDelegate` without actor isolation, and it always calls
/// from the main thread, so the conformance is isolated to the main actor (SE-0470). The bridge keeps that
/// conformance out of the `@Observable` session and makes the weak-reference direction explicit:
/// `processDelegate` is weak, the session retains the bridge.
@MainActor
final class TerminalBridge: NSObject, @MainActor LocalProcessTerminalViewDelegate {
    weak var session: ThreadSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // The view already did the TIOCSWINSZ ioctl; only the model needs the new size.
        session?.handleSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        session?.handleTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        session?.handleDirectory(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        session?.handleExit(rawWaitStatus: exitCode)
    }
}
