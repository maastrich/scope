import Foundation
import ScopeCore

/// Turns review comments into the one block of text a thread receives.
///
/// Each comment names its file, its side and its lines, shows the code with the line numbers the file has *now*
/// (the agent kept editing after the comment was written), then the comment. A comment whose lines cannot be found
/// any more shows the code as it was, and says so, rather than pointing at the wrong place.
public enum ReviewRenderer {
    /// More than this is not a review, it is a rewrite; the rest is counted, not sent.
    public static let maxComments = 60
    /// Lines of the current file shown on each side of the commented ones.
    public static let surrounding = 2

    /// - Parameters:
    ///   - repoName: display name of a repository (`TaskRepo.repoRelativePath` → `api`, or the scope's name).
    ///   - currentFile: the lines of a comment's file as it is now, `nil` when it is gone. Only asked for comments on
    ///     the new side: the old side is the base, which the agent does not edit.
    public static func render(_ comments: [ReviewComment], repoName: (String) -> String,
                              currentFile: (ReviewComment) -> [String]?) -> String {
        let ordered = comments.sorted { ($0.repo, $0.path, $0.anchor.line) < ($1.repo, $1.path, $1.anchor.line) }
        let sent = ordered.prefix(maxComments)
        var out: [String] = []
        let count = sent.count == 1 ? "1 comment" : "\(sent.count) comments"
        out.append("Review of your changes — \(count). Address each one, then say what you changed.")
        for comment in sent {
            out.append("")
            out.append(contentsOf: block(comment, repoName: repoName(comment.repo),
                                         file: comment.side == .new ? currentFile(comment) : nil))
        }
        if ordered.count > sent.count {
            out.append("")
            out.append("(\(ordered.count - sent.count) more comments were not included.)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func block(_ comment: ReviewComment, repoName: String, file: [String]?) -> [String] {
        let anchor = comment.anchor
        let located = file.flatMap { anchor.locate(in: $0) }
        let first = located ?? anchor.line
        let last = first + anchor.span - 1
        let range = anchor.span == 1 ? "line \(first)" : "lines \(first)–\(last)"
        let side = comment.side == .new ? "" : " (removed lines, before the change)"
        var lines = ["## \(repoName)/\(comment.path), \(range)\(side)"]
        var code: [(number: Int?, text: String, marked: Bool)] = []
        if let file, let located {
            let start = max(1, located - surrounding)
            let end = min(file.count, located + anchor.span - 1 + surrounding)
            if start <= end {
                for number in start...end {
                    code.append((number, file[number - 1], (located...last).contains(number)))
                }
            }
        } else {
            if comment.side == .new {
                lines.append(file == nil
                    ? "(The file is gone; this is the code as it was when commented.)"
                    : "(These lines changed since; this is the code as it was when commented.)")
            }
            for (offset, text) in anchor.lines.enumerated() { code.append((anchor.line + offset, text, true)) }
        }
        let width = String(code.compactMap(\.number).max() ?? 0).count
        lines.append("```")
        for entry in code {
            let number = entry.number.map { String($0) } ?? ""
            let pad = String(repeating: " ", count: max(0, width - number.count))
            // No trailing blanks on an empty line: some TUIs trim them from a paste, some editors flag them.
            lines.append("\(entry.marked ? ">" : " ") \(pad)\(number)" + (entry.text.isEmpty ? "" : "  \(entry.text)"))
        }
        lines.append("```")
        lines.append(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines
    }
}

/// Text meant for a terminal program as one input.
public enum ThreadDelivery {
    /// The bracketed-paste envelope (`ESC [200~ … ESC [201~`). A TUI that enabled it — Claude Code, Codex — takes
    /// everything inside as one paste, newlines included, instead of submitting at the first line break. A shell
    /// that did not enable it sees the markers as noise, which is why the submitting `\r` goes separately.
    public static func bracketedPaste(_ text: String) -> String {
        let start = "\u{1b}[200~"
        let end = "\u{1b}[201~"
        // A payload carrying the end marker would close the paste early and type the rest as keystrokes.
        let clean = text.replacingOccurrences(of: end, with: "").replacingOccurrences(of: start, with: "")
        return start + clean + end
    }

    /// Whether a thread can take a message now: alive and not in the middle of a turn. A running agent would
    /// read a paste as typing into its own work; it waits for the turn to end (done, idle, or asking something).
    public static func canDeliver(to state: ThreadState) -> Bool {
        state.isAlive && state != .running
    }
}
