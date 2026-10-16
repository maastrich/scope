import Foundation

/// What a macOS notification about a thread says (spec §4.7). Pure: the app decides *whether* to post
/// (it is not frontmost) and *how* (UserNotifications); this type only decides *what* for a given event.
public struct ThreadNotificationContent: Equatable, Sendable {
    /// `"<driver> · <scope>"` or `"<driver> · <scope> · <task>"`.
    public var title: String
    /// What happened (`needs your answer`, …) when the body quotes the agent instead; `nil` otherwise.
    public var subtitle: String?
    public var body: String

    public init(title: String, subtitle: String? = nil, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// Words of the agent a notification can quote.
    public enum Said: Equatable, Sendable {
        /// The question itself, as the driver put it (a question tool's text, a plan, a dialog's message).
        case question(String)
        /// The agent's last answer: its opening for a finished turn, its closing paragraph for a question —
        /// that is where an answer that ends on a question asks it.
        case reply(String)
    }

    /// Most characters a quoted body keeps; the rest becomes `…`.
    public static let excerptLimit = 180

    /// The content for `event`, or `nil` when the event is not one the user is told about
    /// (only `inputRequested`, `permissionRequested`, `turnEnded` and `turnFailed` notify). `failure` is the
    /// driver's error code for `turnFailed` (`rate_limit`, …), shown in words. `said`, when it has anything left
    /// once Markdown is stripped, becomes the body of a question or a finished turn, and the generic words move to
    /// the subtitle; a permission request and a failed turn keep their words.
    public static func make(event: ThreadStateEvent, driver: String, scope: String, task: String? = nil,
                            failure: String? = nil, said: Said? = nil) -> ThreadNotificationContent? {
        let generic: String
        switch event {
        case .inputRequested: generic = "needs your answer"
        case .permissionRequested: generic = "asks for a permission"
        case .turnEnded: generic = "finished its turn"
        case .turnFailed: generic = "stopped on an error" + (failureDescription(failure).map { ": \($0)" } ?? "")
        case .turnStarted, .threadEnded, .processExited: return nil
        }
        let parts = [driver, scope] + (task.map { [$0] } ?? [])
        let title = parts.joined(separator: " · ")
        guard event == .inputRequested || event == .turnEnded, let quote = said.flatMap({ quoted($0, for: event) }) else {
            return ThreadNotificationContent(title: title, body: generic)
        }
        return ThreadNotificationContent(title: title, subtitle: generic, body: quote)
    }

    private static func quoted(_ said: Said, for event: ThreadStateEvent) -> String? {
        switch said {
        case .question(let text): excerpt(text, from: .opening)
        case .reply(let text): excerpt(text, from: event == .turnEnded ? .opening : .closing)
        }
    }

    /// `true` when a notification is worth posting: the event notifies and the app is not frontmost.
    public static func shouldNotify(event: ThreadStateEvent, appIsActive: Bool) -> Bool {
        guard !appIsActive else { return false }
        switch event {
        case .inputRequested, .permissionRequested, .turnEnded, .turnFailed: return true
        case .turnStarted, .threadEnded, .processExited: return false
        }
    }

    /// `rate_limit` → `rate limit`; `nil` for no code at all.
    public static func failureDescription(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return code.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Excerpt

extension ThreadNotificationContent {
    public enum Edge: Sendable {
        /// The first paragraphs, as many as fit.
        case opening
        /// The last paragraph.
        case closing
    }

    /// `text` as one line of prose a banner can show: code blocks dropped, Markdown markers stripped, whitespace
    /// collapsed, cut to `limit` characters on a word boundary. Headings only count when there is nothing else —
    /// an answer opening on `## Summary` says nothing yet. `nil` when nothing readable is left.
    public static func excerpt(_ text: String, from edge: Edge, limit: Int = excerptLimit) -> String? {
        let blocks = paragraphs(text)
        let prose = blocks.filter { !$0.isHeading }.map(\.text)
        let chosen = prose.isEmpty ? blocks.map(\.text) : prose
        guard !chosen.isEmpty else { return nil }
        let line: String
        switch edge {
        case .opening:
            // A one-word opening ("Done.") is followed by what was done: keep going while there is room.
            var taken: [String] = []
            for paragraph in chosen {
                taken.append(paragraph)
                if taken.joined(separator: " ").count >= limit { break }
            }
            line = taken.joined(separator: " ")
        case .closing:
            line = chosen[chosen.count - 1]
        }
        return capped(line, limit: limit)
    }

    private struct Paragraph {
        var text: String
        var isHeading: Bool
    }

    /// The readable paragraphs of a Markdown text, each cleaned and on one line. A heading is its own paragraph.
    private static func paragraphs(_ text: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: [String] = []
        var fence: Substring?
        func flush() {
            let joined = collapsed(current.joined(separator: " "))
            if !joined.isEmpty { result.append(Paragraph(text: joined, isHeading: false)) }
            current = []
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = line.prefix(3)
                continue
            }
            if line.isEmpty || isRule(line) || isTableSeparator(line) {
                flush()
                continue
            }
            if let heading = line.firstMatch(of: #/^#{1,6}\s+(.*)$/#) {
                flush()
                let text = collapsed(inline(String(heading.1)))
                if !text.isEmpty { result.append(Paragraph(text: text, isHeading: true)) }
                continue
            }
            current.append(inline(block(line)))
        }
        flush()
        return result
    }

    /// `---`, `***`, `___` and the like.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        return marks.count >= 3 && Set(marks).count == 1 && "-*_=".contains(marks.first!)
    }

    /// `|---|:---:|`
    private static func isTableSeparator(_ line: String) -> Bool {
        line.hasPrefix("|") && line.allSatisfy { "|-: ".contains($0) }
    }

    /// The line without its block markers: quote, list bullet or number, task box, table pipes.
    private static func block(_ line: String) -> String {
        var line = line.replacing(#/^(>\s?)+/#, with: "")
        line = line.replacing(#/^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/#, with: "")
        if line.hasPrefix("|") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            line = cells.joined(separator: " · ")
        }
        return line
    }

    /// The line without inline markup: images and links keep their text, emphasis and code marks go.
    private static func inline(_ line: String) -> String {
        var line = line.replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
        line = line.replacing(#/\*\*|__|~~|`/#, with: "")
        // A `*` pair hugging words is emphasis; a `*` between spaces (`2 * 3`) is not.
        line = line.replacing(#/\*(\S(?:[^*]*\S)?)\*/#) { String($0.1) }
        return line
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` within `limit` characters: cut at the last space past half the limit (else mid-word), trailing
    /// punctuation dropped, `…` appended.
    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = text.prefix(limit - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = cut[..<space]
        }
        let trimmed = cut.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ",;:-–—")))
        return trimmed + "…"
    }
}
