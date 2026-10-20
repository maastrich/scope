import Foundation

/// An answer to a Claude Code dialog given from Scope rather than at the terminal, typed as the keys a person would
/// press (verified on Claude Code 2.1.304):
///
/// - a permission: `1` is always *Yes*; Esc cancels, which is *No* whatever the number of options in between
///   (*Yes, and don't ask again…*, *switch to accept edits* come and go with `permission_suggestions`);
/// - one single-choice question: the option's digit, which also submits;
/// - a multiple choice, or several questions: each option's digit toggles it, → moves to the next question, and the
///   last step is a review whose `1` is *Submit answers*.
///
/// Plans (their options change with the settings) and MCP forms are not answered from here: answer them at the
/// terminal.
public enum ClaudeDialogAnswer: Sendable, Equatable, Codable {
    case allow
    case deny
    /// Per question, the options chosen (0-based): one for a single choice, one or more for a multiple choice.
    case choose([[Int]])

    /// Why an answer was not typed.
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        /// This kind of dialog is answered at the terminal.
        case notAnswerable(ClaudePendingRequest.Kind)
        /// The answer does not fit the request (an `allow` for a question, a choice out of range…).
        case invalid(String)
        /// The terminal does not show the dialog the request describes: it closed, another one is up, the screen moved.
        case notOnScreen

        public var description: String {
            switch self {
            case .notAnswerable(.plan): "a plan is approved at the terminal: its options depend on the settings"
            case .notAnswerable(.elicitation): "an MCP server's form is filled in at the terminal"
            case .notAnswerable(let kind): "a \(kind.rawValue) is answered at the terminal"
            case .invalid(let why): why
            case .notOnScreen: "the terminal does not show this dialog any more; nothing was typed"
            }
        }
    }

    /// The keys to type for this answer, each to be written on its own (Claude Code reads one key per read: two in one
    /// write would arrive as a paste).
    public func keys(for request: ClaudePendingRequest) -> Result<[String], Refusal> {
        switch (request.kind, self) {
        case (.permission, .allow):
            return .success(["1"])
        case (.permission, .deny):
            return .success(["\u{1b}"])
        case (.permission, .choose):
            return .failure(.invalid("a permission is allowed or denied"))
        case (.question, .choose(let choices)):
            return Self.keys(for: request.questions, choices: choices)
        case (.question, _):
            return .failure(.invalid("a question is answered by choosing its options"))
        case (.plan, _), (.elicitation, _):
            return .failure(.notAnswerable(request.kind))
        }
    }

    static let right = "\u{1b}[C"

    private static func keys(for questions: [ClaudePendingRequest.Question], choices: [[Int]]) -> Result<[String], Refusal> {
        guard !questions.isEmpty else { return .failure(.invalid("the question has no content to answer")) }
        guard choices.count == questions.count else {
            return .failure(.invalid("\(questions.count) question(s), \(choices.count) answer(s)"))
        }
        var keys: [String] = []
        for (question, chosen) in zip(questions, choices) {
            var picked: [Int] = []
            for index in chosen where !picked.contains(index) { picked.append(index) }
            guard !picked.isEmpty else { return .failure(.invalid("no option chosen for \"\(question.question)\"")) }
            guard question.multiSelect || picked.count == 1 else {
                return .failure(.invalid("\"\(question.question)\" takes one option"))
            }
            // Digits reach the ninth option; AskUserQuestion offers four at most.
            guard picked.allSatisfy({ $0 >= 0 && $0 < question.options.count && $0 < 9 }) else {
                return .failure(.invalid("no such option for \"\(question.question)\""))
            }
            keys += picked.map { String($0 + 1) }
            if question.multiSelect { keys.append(right) }
        }
        // A lone single choice submits with its digit; anything else ends on the review, whose 1 is *Submit answers*.
        if questions.count > 1 || questions[0].multiSelect { keys.append("1") }
        return .success(keys)
    }

    /// Whether Scope can answer `request` at all: a permission it can tell from another on screen, a question whose
    /// every part has options. A plan or a form is answered at the terminal.
    public static func isAnswerable(_ request: ClaudePendingRequest) -> Bool {
        switch request.kind {
        case .permission: fragments(of: request) != nil
        case .question: !request.questions.isEmpty && request.questions.allSatisfy { !$0.options.isEmpty }
        case .plan, .elicitation: false
        }
    }

    // MARK: The screen

    /// `nil` when the bottom of `screen` (the terminal's lines, oldest first, as text) shows the dialog `request`
    /// describes, else why not. What is read is the dialog alone — from its prompt line up to the conversation above
    /// it — so a command the transcript echoes above a different dialog does not count.
    public static func check(_ request: ClaudePendingRequest, screen: [String]) -> Refusal? {
        let lines = screen.map(normalized)
        switch request.kind {
        case .permission:
            guard let region = dialog(lines, marker: "Do you want to"),
                  region.contains(where: { $0.range(of: #"^(❯ ?)?1\. Yes\b"#, options: .regularExpression) != nil }),
                  let fragments = fragments(of: request), !fragments.isEmpty,
                  fragments.allSatisfy({ fragment in region.contains { $0.contains(fragment) } })
            else { return .notOnScreen }
            return nil
        case .question:
            guard let first = request.questions.first, let option = first.options.first,
                  let region = dialog(lines, marker: "Enter to select"),
                  !region.contains(where: { $0.contains("Review your answers") }),
                  region.contains(where: { $0.contains(prefix(first.question)) }),
                  region.contains(where: { line in Self.isFirstOption(line, label: option.label) })
            else { return .notOnScreen }
            return nil
        case .plan, .elicitation:
            return .notAnswerable(request.kind)
        }
    }

    /// `❯ 1. Red`, or `1. [ ] Lint` for a multiple choice.
    static func isFirstOption(_ line: String, label: String) -> Bool {
        var rest = Substring(line)
        if rest.hasPrefix("❯") { rest = rest.dropFirst().drop { $0 == " " } }
        guard rest.hasPrefix("1. ") else { return false }
        rest = rest.dropFirst(3)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        return rest.hasPrefix(normalized(label))
    }

    /// The dialog at the bottom of the screen: from the last line holding `marker` down to the bottom, and up to the
    /// first line of the conversation above it (`⏺` a message or a tool, `⎿` its output), at most `regionLimit` lines
    /// above. `nil` when the marker is not near the bottom: the dialog closed and the conversation went on below it.
    static func dialog(_ lines: [String], marker: String) -> [String]? {
        guard let found = lines.lastIndex(where: { $0.contains(marker) }),
              lines[found...].filter({ !$0.isEmpty }).count <= bottomLimit else { return nil }
        var start = found
        while start > 0, found - start < regionLimit {
            let above = lines[start - 1]
            if above.hasPrefix("⏺") || above.hasPrefix("⎿") { break }
            start -= 1
        }
        return Array(lines[start...])
    }

    /// Lines a dialog draws under its prompt line at most: its options and its key hints.
    static let bottomLimit = 16

    static let regionLimit = 40

    /// What the dialog must show for it to be this request's: the command's start, the file's name, the MCP server,
    /// the URL's host. `nil` when nothing tells this request from another — then it is not answered.
    static func fragments(of request: ClaudePendingRequest) -> [String]? {
        if let command = request.command,
           let line = command.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) {
            return [prefix(String(line))]
        }
        if let server = request.mcpServer { return [server, "(MCP)"] }
        if let path = request.filePath {
            let name = (path as NSString).lastPathComponent
            return [name.isEmpty ? path : name]
        }
        if let url = request.url { return [URL(string: url)?.host() ?? prefix(url)] }
        if let query = request.query { return [prefix(query)] }
        return nil
    }

    /// The start of a text as the dialog draws it on one line: whitespace collapsed, short enough not to wrap.
    static func prefix(_ text: String) -> String {
        String(normalized(text).prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    /// A row with its blanks made one space. The emulator hands back NUL for the cells a TUI skipped with the cursor
    /// rather than wrote spaces in — between the words of a dialog, as often as not.
    static func normalized(_ line: String) -> String {
        line.split { $0.isWhitespace || $0 == "\0" || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } == true }
            .joined(separator: " ")
    }
}
