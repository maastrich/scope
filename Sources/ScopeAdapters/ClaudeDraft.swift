import Foundation

/// One row of a terminal's screen, as the input reader needs it: the characters, and which of them are drawn dim
/// (SGR 2). Claude Code draws its placeholder (`Try "fix lint errors"`) and its completions dim, never what was typed.
public struct ScreenRow: Sendable, Equatable {
    public var cells: [Cell]

    public struct Cell: Sendable, Equatable {
        public var character: Character
        public var dim: Bool

        public init(_ character: Character, dim: Bool = false) {
            self.character = character
            self.dim = dim
        }
    }

    public init(cells: [Cell]) {
        self.cells = cells
    }

    /// A row of plain text; `dim` marks the characters from that offset on as dim.
    public init(_ text: String, dimFrom: Int? = nil) {
        cells = text.enumerated().map { offset, character in Cell(character, dim: dimFrom.map { offset >= $0 } ?? false) }
    }

    public var text: String { String(cells.map(\.character)) }

    /// What a person typed: the dim characters left out.
    var typed: String { String(cells.filter { !$0.dim }.map(\.character)) }
}

/// The input field at the bottom of Claude Code's screen (verified on 2.1.308): a `❯` row (`!` in shell mode)
/// between two `─` rules, continuation rows indented by two columns, and above the top rule a hint row that says
/// `› stashed` while a stashed prompt waits.
///
/// ```
///                                                                       › stashed
/// ──────────────────────────────────────────────────── (the top rule may read ─── History 3/7 ───)
/// ❯ first line of the draft
///   second line
/// ────────────────────────────────────────────────────
///   ⏵⏵ auto mode on (shift+tab to cycle)
/// ```
///
/// Past prompts, queued messages and menus (`❯ 5. Haiku`) start with `❯` too: only the last framed one counts.
/// A dialog in place of the field (a permission, a question, `/model`) leaves no field to read.
public struct ClaudePromptInput: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// `❯`: a prompt for Claude.
        case prompt
        /// `!`: a command for the shell, which typing `!` into an empty field enters and Backspace leaves.
        case shell
    }

    public var mode: Mode
    /// The draft as drawn, rows joined by `\n`, trailing blanks dropped; empty for a field showing its placeholder.
    /// A soft-wrapped line reads as two: the text is for telling drafts apart, never for typing back.
    public var text: String
    /// `› stashed`: the field holds an earlier Ctrl+S, which a new one would replace.
    public var stashHeld: Bool

    public init(mode: Mode = .prompt, text: String, stashHeld: Bool = false) {
        self.mode = mode
        self.text = text
        self.stashHeld = stashHeld
    }

    /// Nothing typed and no mode entered: a message goes in as it is.
    public var isEmpty: Bool { mode == .prompt && text.isEmpty }

    static let promptGlyph: Character = "❯"
    static let shellGlyph: Character = "!"
    static let rule: Character = "─"
    static let stashHint = "› stashed"
    /// More rows than any field Claude Code draws on a terminal: past that, two rules are not one field.
    static let maxRows = 60

    /// The field on `rows`, the bottom of the screen; `nil` when the screen shows none.
    public static func read(_ rows: [ScreenRow]) -> ClaudePromptInput? {
        field(rows).map { ClaudePromptInput(mode: $0.mode, text: $0.text, stashHeld: $0.stashHeld) }
    }

    /// The field's rows as drawn, the glyph and the indent taken off, trailing blanks dropped.
    static func field(_ rows: [ScreenRow]) -> (mode: Mode, lines: [String], text: String, stashHeld: Bool)? {
        guard let bottom = rows.lastIndex(where: isRule), bottom > 0 else { return nil }
        let lowest = max(0, bottom - maxRows)
        guard let top = rows[lowest..<bottom].lastIndex(where: isRule), top + 1 < bottom else { return nil }
        let field = rows[(top + 1)..<bottom]
        let first = field[field.startIndex].typed
        let mode: Mode
        switch first.first {
        case promptGlyph?: mode = .prompt
        case shellGlyph?: mode = .shell
        default: return nil
        }
        // The glyph, then U+00A0 (a space on older builds), then the text; every other row is indented by two.
        var lines = [String(first.dropFirst(2))]
        for row in field.dropFirst() {
            let typed = row.typed
            guard typed.prefix(2).allSatisfy({ $0 == " " || $0 == "\u{a0}" }) else { return nil }
            lines.append(String(typed.dropFirst(2)))
        }
        let trimmed = lines.map { trimTrailing($0) }
        let text = trimmed.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let hint = rows[lowest..<top].suffix(2).contains { $0.text.contains(stashHint) }
        return (mode, trimmed, text, hint)
    }

    /// A row drawn as a rule: starts with `─` and is mostly `─` (a label such as `History 3/7` may sit in it).
    static func isRule(_ row: ScreenRow) -> Bool {
        let text = row.text.trimmingCharacters(in: CharacterSet(charactersIn: " \u{a0}\0"))
        guard text.first == rule, text.count >= 20 else { return false }
        return text.filter { $0 == rule }.count * 4 >= text.count * 3
    }

    private static func trimTrailing(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\u{a0}" || last == "\0" { line = line.dropLast() }
        return String(line)
    }
}

/// Keeping the user's half-typed prompt out of a message Scope types into a Claude Code thread.
///
/// Typed on top of a draft, a message would join it and both would be submitted. Claude Code's own stash does the
/// whole job: Ctrl+S takes the draft out of the field (multi-line text, pasted blocks, images, shell mode, the
/// cursor), and the next submit puts it back on its own (*Draft restored*), whether the turn starts or the
/// message is queued behind a running one. Scope reads the field first, so it never presses Ctrl+S on an empty
/// field (that would bring an older stash back into the message) and never on a dialog.
public enum ClaudeDraft {
    /// Ctrl+S, Claude Code's *stash prompt*: on a field with text, stashes it; on an empty one, brings the stash back.
    public static let stash = "\u{13}"
    /// Backspace on an empty `!` field leaves shell mode, where a message would run as a command.
    public static let leaveShell = "\u{7f}"
    /// Typed into an empty field, enters shell mode again.
    public static let enterShell = "!"

    /// How long a field holding a draft and an older stash is given to clear before the draft is stashed anyway.
    public static let stashHeldPatience: Duration = .seconds(20)
    /// How long each step may take to show on screen: the field emptied, the draft back.
    public static let settleTimeout: Duration = .milliseconds(1_500)
    /// How often the screen is read again while waiting on a step.
    public static let pollInterval: Duration = .milliseconds(50)

    /// What to do with the field before typing a message.
    public enum Plan: Sendable, Equatable {
        /// Type the message as Scope always has: nothing in the field, a dialog on screen, or a driver without a stash.
        case asIs
        /// Stash the draft; Claude Code puts it back once the message is submitted.
        case stash
        /// Empty shell mode: leave it, then enter it again after the message.
        case leaveShell
        /// A draft and an older stash: stashing would lose the older one. Ask again in a moment.
        case wait
    }

    /// `claudeInput`: the profile is Claude Code's; `dialog`: Scope knows the thread waits on a permission, a question
    /// or a menu; `field`: what `ClaudePromptInput.read` found; `userStashed`: the user pressed Ctrl+S since their last
    /// submit (the hint row can be covered by another); `waited`: how long this message has been held for a stash.
    public static func plan(claudeInput: Bool, dialog: Bool, field: ClaudePromptInput?, userStashed: Bool,
                            waited: Duration) -> Plan {
        guard claudeInput, !dialog, let field, !field.isEmpty else { return .asIs }
        if field.mode == .shell, field.text.isEmpty { return .leaveShell }
        if field.stashHeld || userStashed, waited < stashHeldPatience { return .wait }
        return .stash
    }

    /// The field after a Ctrl+S or a Backspace: empty, ready for the message.
    public static func isCleared(_ field: ClaudePromptInput?) -> Bool {
        field?.isEmpty == true
    }

    /// The field after the message was submitted: the draft back as it was.
    public static func isRestored(_ draft: ClaudePromptInput, on field: ClaudePromptInput?) -> Bool {
        guard let field else { return false }
        return field.mode == draft.mode && field.text == draft.text
    }

    /// The field after the message, stashed draft still not back: an empty field under `› stashed`, where a Ctrl+S
    /// brings it back by hand.
    public static func needsUnstash(_ field: ClaudePromptInput?) -> Bool {
        guard let field else { return false }
        return field.isEmpty && field.stashHeld
    }
}

// MARK: Retyping a draft

extension ClaudeDraft {
    /// A draft read off the screen to be typed back into a new Claude Code process (Restart Session): the stash dies
    /// with the process, so the text is all there is.
    public struct Retype: Sendable, Equatable {
        public var mode: ClaudePromptInput.Mode
        public var text: String
        /// `[Pasted text #N …]` and `[Image #N]` left out: they name content only the old process held, and typed
        /// back they would be literal text.
        public var droppedAttachments: Int

        public init(mode: ClaudePromptInput.Mode, text: String, droppedAttachments: Int = 0) {
            self.mode = mode
            self.text = text
            self.droppedAttachments = droppedAttachments
        }
    }

    /// The draft on `rows`, a screen `columns` wide, as it was typed: Claude Code wraps a long line itself, with
    /// real line breaks the terminal cannot tell from the user's, so a row is joined to the next when the next one's
    /// first word could not have fitted on it — Claude Code breaks at words. `nil` with nothing worth typing back.
    public static func retype(_ rows: [ScreenRow], columns: Int) -> Retype? {
        guard let field = ClaudePromptInput.field(rows) else { return nil }
        // The glyph and the space before the text, then a margin Claude Code keeps on the right.
        let width = columns - 2 - wrapSlack
        var text = ""
        for (index, line) in field.lines.enumerated() {
            text += line
            guard index + 1 < field.lines.count else { break }
            let next = field.lines[index + 1]
            let firstWord = next.prefix { $0 != " " }
            let wrapped = !line.isEmpty && !firstWord.isEmpty && line.count + 1 + firstWord.count > width
            text += wrapped ? " " : "\n"
        }
        var dropped = 0
        for pattern in attachmentPatterns {
            let matches = text.matches(of: pattern).count
            guard matches > 0 else { continue }
            dropped += matches
            text = text.replacing(pattern, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || field.mode == .shell || dropped > 0 else { return nil }
        return Retype(mode: field.mode, text: text, droppedAttachments: dropped)
    }

    /// Columns Claude Code leaves free at the right of its field before it wraps.
    static let wrapSlack = 2
    nonisolated(unsafe) static let attachmentPatterns: [Regex<Substring>] = [
        /\[Pasted text #\d+[^\]]*\]/,
        /\[Image #\d+[^\]]*\]/,
    ]
}
