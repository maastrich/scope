import Foundation
import Testing
@testable import ScopeAdapters

/// `ClaudePromptInput` and `ClaudeDraft`: reading Claude Code's input field off the screen, and what to do with a
/// draft before Scope types a message. Screens are the bottom of Claude Code 2.1.308's terminal (100 columns) as
/// captured in the probe runs for this change.
@Suite struct ClaudeDraftTests {
    static let rule = String(repeating: "─", count: 100)
    static let nbsp = "\u{a0}"

    static func screen(_ rows: [ScreenRow]) -> [ScreenRow] {
        [ScreenRow("⏺ PONG"), ScreenRow(""), ScreenRow("✻ Churned for 2s · done 10:24 AM")] + rows + [
            ScreenRow("  scope(fix/keep-draft-on-injected-message) claude-haiku-5-5 ctx:7.00%"),
            ScreenRow("  ⏵⏵ auto mode on (shift+tab to cycle)"),
        ]
    }

    static let empty = screen([
        ScreenRow(rule),
        ScreenRow("❯\(nbsp)Try \"fix lint errors\"", dimFrom: 2),
        ScreenRow(rule),
    ])

    static let multiline = screen([
        ScreenRow(String(repeating: " ", count: 80) + "Draft restored"),
        ScreenRow(rule),
        ScreenRow("❯\(nbsp)line one of draft"),
        ScreenRow("  line two   "),
        ScreenRow(rule),
    ])

    @Test func emptyFieldShowsItsPlaceholder() throws {
        let field = try #require(ClaudePromptInput.read(Self.empty))
        #expect(field == ClaudePromptInput(text: ""))
        #expect(field.isEmpty)
    }

    @Test func multilineDraft() throws {
        let field = try #require(ClaudePromptInput.read(Self.multiline))
        #expect(field.text == "line one of draft\nline two")
        #expect(field.mode == .prompt)
        #expect(!field.stashHeld)
    }

    @Test func pastedBlockIsTypedText() throws {
        let rows = Self.screen([
            ScreenRow(Self.rule),
            ScreenRow("❯\(Self.nbsp)count lines: [Pasted text #1 +15 lines]"),
            ScreenRow(Self.rule),
        ])
        #expect(ClaudePromptInput.read(rows)?.text == "count lines: [Pasted text #1 +15 lines]")
    }

    @Test func completionSuffixIsNotTheDraft() throws {
        let rows = Self.screen([
            ScreenRow(Self.rule),
            ScreenRow("❯\(Self.nbsp)/mo del", dimFrom: 5),
            ScreenRow(Self.rule),
        ])
        #expect(ClaudePromptInput.read(rows)?.text == "/mo")
    }

    @Test func stashHint() throws {
        let rows = Self.screen([
            ScreenRow(String(repeating: " ", count: 60) + "Draft restored · › stashed"),
            ScreenRow(Self.rule),
            ScreenRow("❯\(Self.nbsp)other text"),
            ScreenRow(Self.rule),
        ])
        let field = try #require(ClaudePromptInput.read(rows))
        #expect(field.stashHeld)
        #expect(field.text == "other text")
    }

    @Test func historyRuleAndShellMode() throws {
        let rows = Self.screen([
            ScreenRow("─── History 7/7 " + String(repeating: "─", count: 84)),
            ScreenRow("!\(Self.nbsp)ls -la"),
            ScreenRow(Self.rule),
        ])
        #expect(ClaudePromptInput.read(rows) == ClaudePromptInput(mode: .shell, text: "ls -la"))
        let bare = Self.screen([ScreenRow(Self.rule), ScreenRow("!"), ScreenRow(Self.rule)])
        let field = try #require(ClaudePromptInput.read(bare))
        #expect(field.mode == .shell && field.text.isEmpty && !field.isEmpty)
    }

    /// Past prompts and queued messages start with `❯` too; only the framed field at the bottom counts.
    @Test func onlyTheLastFramedField() throws {
        let rows = [
            ScreenRow("❯ run the shell command: sleep 20"),
            ScreenRow("❯ auto message: say QUEUED afterwards"),
            ScreenRow("  ctrl+x ctrl+s to send now"),
        ] + Self.multiline
        #expect(ClaudePromptInput.read(rows)?.text == "line one of draft\nline two")
    }

    /// `/model`, a permission: a dialog stands where the field was.
    @Test func dialogsHaveNoField() {
        let menu = [
            ScreenRow("     4.  Sonnet 5.5             Most efficient for simpler tasks"),
            ScreenRow("   ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers"),
            ScreenRow("     6.  Haiku 4.5              Fastest for quick answers"),
            ScreenRow(""),
            ScreenRow("   Enter to set as default · s to use this session only · Esc to cancel"),
        ]
        #expect(ClaudePromptInput.read(menu) == nil)
        let permission = [
            ScreenRow(Self.rule),
            ScreenRow(" Bash command"),
            ScreenRow("   sleep 20 && echo done"),
            ScreenRow(" Do you want to proceed?"),
            ScreenRow(" ❯ 1. Yes"),
            ScreenRow("   2. No"),
        ]
        #expect(ClaudePromptInput.read(permission) == nil)
        #expect(ClaudePromptInput.read([]) == nil)
        #expect(ClaudePromptInput.read([ScreenRow("$ ls"), ScreenRow("a b c")]) == nil)
    }

    @Test func plans() {
        let draft = ClaudePromptInput(text: "half typed")
        func plan(_ field: ClaudePromptInput?, claude: Bool = true, dialog: Bool = false, userStashed: Bool = false,
                  waited: Duration = .zero) -> ClaudeDraft.Plan {
            ClaudeDraft.plan(claudeInput: claude, dialog: dialog, field: field, userStashed: userStashed, waited: waited)
        }
        #expect(plan(draft) == .stash)
        #expect(plan(ClaudePromptInput(text: "")) == .asIs)
        #expect(plan(nil) == .asIs)
        #expect(plan(draft, claude: false) == .asIs)
        #expect(plan(draft, dialog: true) == .asIs)
        #expect(plan(ClaudePromptInput(mode: .shell, text: "")) == .leaveShell)
        #expect(plan(ClaudePromptInput(mode: .shell, text: "ls")) == .stash)
        // An older stash would be lost: wait for the field to clear, then stash anyway.
        #expect(plan(ClaudePromptInput(text: "again", stashHeld: true)) == .wait)
        #expect(plan(draft, userStashed: true) == .wait)
        #expect(plan(draft, userStashed: true, waited: ClaudeDraft.stashHeldPatience) == .stash)
        // An empty field under a stash takes the message as it is: Claude Code brings the stash back after it.
        #expect(plan(ClaudePromptInput(text: "", stashHeld: true)) == .asIs)
    }

    @Test func steps() {
        let draft = ClaudePromptInput(text: "line one\nline two")
        #expect(ClaudeDraft.isCleared(ClaudePromptInput(text: "", stashHeld: true)))
        #expect(!ClaudeDraft.isCleared(draft))
        #expect(!ClaudeDraft.isCleared(nil))
        #expect(!ClaudeDraft.isCleared(ClaudePromptInput(mode: .shell, text: "")))
        #expect(ClaudeDraft.isRestored(draft, on: ClaudePromptInput(text: "line one\nline two")))
        #expect(!ClaudeDraft.isRestored(draft, on: ClaudePromptInput(mode: .shell, text: "line one\nline two")))
        #expect(!ClaudeDraft.isRestored(draft, on: nil))
        #expect(ClaudeDraft.needsUnstash(ClaudePromptInput(text: "", stashHeld: true)))
        #expect(!ClaudeDraft.needsUnstash(ClaudePromptInput(text: "")))
        #expect(ClaudeDraft.stash.utf8.elementsEqual([0x13]))
        #expect(ClaudeDraft.leaveShell.utf8.elementsEqual([0x7f]))
    }
}
