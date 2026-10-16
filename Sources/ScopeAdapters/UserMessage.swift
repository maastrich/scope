import Foundation
import ScopeCore

/// What the user types to a thread from Scope's own chrome — *Ask Orchestrator…*, *Send to Thread…*, the sidebar's
/// inline reply — rather than in its terminal: who it goes to, when it can be typed, and what is shown beside it.
public enum UserMessage {
    /// `text` as it should be typed: AppKit's line and paragraph separators (what ⇧↩ inserts in a text view) made
    /// plain newlines, which `ThreadDelivery.input` knows how to paste, and the blank edges dropped. `nil` when
    /// nothing is left to send.
    public static func normalized(_ text: String) -> String? {
        let plain = text
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }

    /// The orchestrator of `scope`: the first record of the scope to claim the role, the one `ResidentReconciliation`
    /// keeps. `nil` when the scope has none — no agent profile was installed when it was declared.
    public static func orchestrator(of scope: ScopeID, in records: [ThreadRecord]) -> ThreadID? {
        records.first { $0.scopeID == scope && $0.resident == .orchestrator }?.id
    }

    // MARK: Palette

    /// Words from which the palette's query reads as a sentence to send rather than a name to look up.
    public static let sentenceWords = 3

    /// Whether the palette offers *Ask Orchestrator: <query>* below its results. Always when nothing matched (so
    /// ⌘K, type, ↩ sends); also, last, when the query reads as a sentence, which a fuzzy match on file paths
    /// otherwise buries. Never without an orchestrator to ask.
    public static func offersAsk(query: String, matches: Int, hasOrchestrator: Bool) -> Bool {
        guard hasOrchestrator else { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return matches == 0 || query.split(whereSeparator: \.isWhitespace).count >= sentenceWords
    }

    // MARK: Starting a thread to talk to it

    /// How long a thread just started gets to show it reads input before the message goes anyway.
    public static let startupTimeout: Duration = .seconds(8)

    /// Whether a message held for a thread being started can be typed now. A TUI that turned bracketed paste on
    /// has drawn its prompt and will take a multiline paste whole; typed earlier, the text lands in a shell that is
    /// still starting the driver, or reaches the driver bare and is submitted at its first line break. A program
    /// that never turns it on (a plain `read`) gets the text once the timeout is over.
    public static func canTypeIntoStartedThread(alive: Bool, bracketedPaste: Bool, waited: Duration) -> Bool {
        guard alive else { return false }
        return bracketedPaste || waited >= startupTimeout
    }

    // MARK: Inline reply

    /// The end of the thread's last answer to show above an inline reply: its last `lines` non-blank lines, where a
    /// question or a conclusion sits — `AgentReply` keeps a long answer's end, not its start. `nil` without an
    /// answer, and for one older than the last prompt: it answers something else.
    public static func replyExcerpt(_ reply: AgentReply?, lastPromptAt: Date?, lines: Int = 4) -> String? {
        guard let reply, lines > 0 else { return nil }
        if let lastPromptAt, reply.at < lastPromptAt { return nil }
        let kept = reply.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}
