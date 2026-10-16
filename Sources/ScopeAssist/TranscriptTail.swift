import Foundation
import ScopeControl

/// The end of a thread's terminal, as a model may read it: ANSI stripped, cut to a token budget from the end, and
/// quoted between the untrusted-output markers `thread.read` already uses.
public enum TranscriptTail {
    /// Roughly 3 k tokens, what leaves the on-device model (4 k of context) room for the instructions and the answer.
    public static let defaultTokenBudget = 3000
    /// Characters per token, a coarse figure that holds for English prose and code alike.
    public static let charactersPerToken = 4

    /// CSI sequences (`ESC [ … m`), OSC sequences (`ESC ] … BEL` / `ESC \`), and the other two-byte escapes.
    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]|\u{1b}\\][^\u{7}\u{1b}]*(?:\u{7}|\u{1b}\\\\)|\u{1b}[@-Z\\\\-_]"
    )

    /// `line` without escape sequences, control bytes or trailing blanks.
    public static func stripped(_ line: String) -> String {
        let text = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return ThreadTranscript.cleaned(text).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// The last lines of `lines` that fit `tokenBudget`, blank runs collapsed, closing marker defused.
    public static func text(of lines: [String], tokenBudget: Int = defaultTokenBudget) -> String {
        var kept: [String] = []
        var characters = 0
        let budget = tokenBudget * charactersPerToken
        for raw in lines.reversed() {
            let line = stripped(raw)
            if line.isEmpty, kept.last?.isEmpty ?? true { continue }
            if characters + line.count + 1 > budget { break }
            characters += line.count + 1
            kept.append(line)
        }
        while kept.last?.isEmpty ?? false { kept.removeLast() }
        return ThreadTranscript.defused(kept.reversed().joined(separator: "\n"))
    }

    /// `text(of:)` between the markers, under the notice a reader is given.
    public static func quoted(_ lines: [String], tokenBudget: Int = defaultTokenBudget) -> String {
        quoting(text(of: lines, tokenBudget: tokenBudget))
    }

    /// Any text between the markers: a reply, a brief.
    public static func quoting(_ text: String) -> String {
        [ThreadTranscript.untrustedNotice, ThreadTranscript.openMarker, ThreadTranscript.defused(text), ThreadTranscript.closeMarker]
            .joined(separator: "\n")
    }

    /// Roughly how many tokens `text` costs.
    public static func tokens(in text: String) -> Int {
        (text.count + charactersPerToken - 1) / charactersPerToken
    }
}
