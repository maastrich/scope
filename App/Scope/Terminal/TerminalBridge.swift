import AppKit
import ScopeAdapters
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

extension TerminalBridge {
    /// Every line the thread's terminal holds, scrollback first then the screen, and the absolute number of the
    /// first one: SwiftTerm trims the oldest scrollback lines and counts them, so numbers stay put as it grows.
    /// A TUI on the alternate screen has no scrollback: its screen is all there is.
    static func transcript(of session: ThreadSession) -> (lines: [String], firstLineNumber: Int) {
        let terminal = session.terminalView.getTerminal()
        let text = String(decoding: terminal.getBufferAsData(kind: .active), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return (lines, terminal.buffer.totalLinesTrimmed)
    }

    /// The rows on the thread's screen — the bottom of the buffer, wherever the user scrolled the view — with which
    /// cells are dim, which is how Claude Code tells its placeholder from typed text (`ClaudePromptInput`).
    static func screenRows(of session: ThreadSession) -> [ScreenRow] {
        let terminal = session.terminalView.getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        // The buffer's length is not public: the last line is the first index past which there is none.
        var low = first, high = first + 1
        while terminal.getScrollInvariantLine(row: high) != nil { high = high * 2 - first + 1 }
        while low + 1 < high {
            let mid = (low + high) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid }
        }
        let top = max(first, low - terminal.rows + 1)
        return (top...low).compactMap { row in
            guard let line = terminal.getScrollInvariantLine(row: row) else { return nil }
            let cells = (0..<min(line.count, terminal.cols)).map { column -> ScreenRow.Cell in
                let cell = line[column]
                let character = cell.getCharacter()
                // SwiftTerm leaves never-written cells as NUL.
                return ScreenRow.Cell(character == "\0" ? " " : character, dim: cell.attribute.style.contains(.dim))
            }
            return ScreenRow(cells: cells)
        }
    }
}
