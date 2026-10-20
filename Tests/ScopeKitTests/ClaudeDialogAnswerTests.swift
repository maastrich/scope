import Foundation
import Testing
@testable import ScopeAdapters

/// `ClaudeDialogAnswer`: the keys an answer types, and the screen check that comes first. Screens are the bottom of
/// Claude Code 2.1.304's terminal as captured in the probe runs (`ClaudePendingFixtures`).
@Suite struct ClaudeDialogAnswerTests {
    static func request(_ payloads: [String]) throws -> ClaudePendingRequest {
        var pending = ClaudePendingRequests()
        for payload in payloads {
            pending.apply(ClaudeHookFacts(body: try #require(JSONValue(json: payload)), at: .now))
        }
        return try #require(pending.current)
    }

    static func bash() throws -> ClaudePendingRequest { try request(Array(ClaudePendingFixtures.bash[2...3])) }
    static func single() throws -> ClaudePendingRequest { try request([ClaudePendingFixtures.question[1]]) }
    static func multi() throws -> ClaudePendingRequest { try request([ClaudePendingFixtures.multiSelect]) }
    static func two() throws -> ClaudePendingRequest { try request([ClaudePendingFixtures.twoQuestions]) }

    static let stackedScreen = """
    ⏺ Bash(echo probe alpha)
      ⎿  Waiting…
    ⏺ Bash(echo probe beta)
      ⎿  Waiting…

    ────────────────────────────────────────────────────────────
     Bash command

       echo probe alpha
       Print probe alpha

     Permission rule Bash(echo probe:*) requires confirmation for this command.
     /permissions to update rules

     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend · 1 of 2
    """.components(separatedBy: "\n")

    static let questionScreen = """
    ⏺ I'll ask you which color to use.

    ────────────────────────────────────────────────────────────
     ☐ Color

    Which color should the probe use?

    ❯ 1. Red
         Warm tone
      2. Blue
         Cool tone
      3. Type something.
    ────────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """.components(separatedBy: "\n")

    static let multiScreen = """
    ────────────────────────────────────────────────────────────
    ←  ☐ Checks  ✔ Submit  →

    Which checks should run?

    ❯ 1. [ ] Lint
             Style
      2. [ ] Tests
             Unit tests
      3. [ ] Build
             Compile
      4. [ ] Type something
         Submit
    ────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """.components(separatedBy: "\n")

    static let reviewScreen = """
    ←  ☒ Checks  ✔ Submit  →

    Review your answers

     ● Which checks should run?
       → Lint, Build

    Ready to submit your answers?

    ❯ 1. Submit answers
      2. Cancel
    """.components(separatedBy: "\n")

    static let promptScreen = """
    ⏺ The command echo probe alpha ran and printed probe alpha.

    ────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────
      ⏸ manual mode on · ? for shortcuts
    """.components(separatedBy: "\n")

    // MARK: Keys

    @Test("a permission is 1 to allow and Esc to deny, whatever options lie between")
    func permissionKeys() throws {
        let bash = try Self.bash()
        #expect(ClaudeDialogAnswer.allow.keys(for: bash) == .success(["1"]))
        #expect(ClaudeDialogAnswer.deny.keys(for: bash) == .success(["\u{1b}"]))
        #expect(ClaudeDialogAnswer.choose([[0]]).keys(for: bash) == .failure(.invalid("a permission is allowed or denied")))
    }

    @Test("a single choice is its digit; a multiple choice toggles, moves on and submits; two questions end on the review")
    func questionKeys() throws {
        #expect(ClaudeDialogAnswer.choose([[1]]).keys(for: try Self.single()) == .success(["2"]))
        #expect(ClaudeDialogAnswer.choose([[0, 2, 0]]).keys(for: try Self.multi()) == .success(["1", "3", "\u{1b}[C", "1"]))
        #expect(ClaudeDialogAnswer.choose([[1], [0]]).keys(for: try Self.two()) == .success(["2", "1", "1"]))
    }

    @Test("an answer that does not fit the question is refused before anything is typed")
    func invalidChoices() throws {
        let single = try Self.single()
        for answer: ClaudeDialogAnswer in [.choose([[0, 1]]), .choose([[]]), .choose([[5]]), .choose([[0], [0]]), .allow] {
            guard case .failure(.invalid) = answer.keys(for: single) else {
                Issue.record("\(answer) was not refused")
                continue
            }
        }
    }

    @Test("a plan and an MCP form are answered at the terminal")
    func notAnswerable() throws {
        let plan = try Self.request(ClaudePendingFixtures.plan)
        #expect(!ClaudeDialogAnswer.isAnswerable(plan))
        #expect(ClaudeDialogAnswer.isAnswerable(try Self.bash()))
        #expect(ClaudeDialogAnswer.isAnswerable(try Self.two()))
        #expect(ClaudeDialogAnswer.allow.keys(for: plan) == .failure(.notAnswerable(.plan)))
        let form = try Self.request(Array(ClaudePendingFixtures.elicitation[4...5]))
        #expect(ClaudeDialogAnswer.deny.keys(for: form) == .failure(.notAnswerable(.elicitation)))
        #expect(ClaudeDialogAnswer.check(form, screen: Self.promptScreen) == .notAnswerable(.elicitation))
    }

    // MARK: Screen

    @Test("of two stacked permissions, only the one the dialog draws passes, not the one echoed above it")
    func stackedScreen() throws {
        let stacked = try Self.request(Array(ClaudePendingFixtures.stacked[2...6]))
        #expect(stacked.command == "echo probe alpha")
        #expect(ClaudeDialogAnswer.check(stacked, screen: Self.stackedScreen) == nil)
        var pending = ClaudePendingRequests()
        for payload in ClaudePendingFixtures.stacked[2...7] {
            pending.apply(ClaudeHookFacts(body: try #require(JSONValue(json: payload)), at: .now))
        }
        let beta = try #require(pending.current)
        #expect(beta.command == "echo probe beta")
        #expect(ClaudeDialogAnswer.check(beta, screen: Self.stackedScreen) == .notOnScreen)
    }

    @Test("a question passes on its own dialog, not on the review step nor once the dialog is gone")
    func questionScreen() throws {
        let single = try Self.single()
        #expect(ClaudeDialogAnswer.check(single, screen: Self.questionScreen) == nil)
        #expect(ClaudeDialogAnswer.check(single, screen: Self.reviewScreen) == .notOnScreen)
        #expect(ClaudeDialogAnswer.check(single, screen: Self.promptScreen) == .notOnScreen)
        #expect(ClaudeDialogAnswer.check(try Self.bash(), screen: Self.questionScreen) == .notOnScreen)
        #expect(ClaudeDialogAnswer.check(try Self.multi(), screen: Self.multiScreen) == nil)
        #expect(ClaudeDialogAnswer.check(try Self.multi(), screen: Self.questionScreen) == .notOnScreen)
    }

    @Test("blank cells the emulator hands back as NUL read as spaces")
    func nulCells() throws {
        let screen = Self.stackedScreen.map { $0.replacingOccurrences(of: " ", with: "\0") }
        #expect(ClaudeDialogAnswer.check(try Self.request(Array(ClaudePendingFixtures.stacked[2...6])), screen: screen) == nil)
    }

    @Test("a dialog that closed and scrolled up is not the one on screen")
    func closedDialog() throws {
        let scrolled = Self.stackedScreen + Array(repeating: "⏺ more output", count: 20) + Self.promptScreen
        #expect(ClaudeDialogAnswer.check(try Self.request(Array(ClaudePendingFixtures.stacked[2...6])),
                                         screen: scrolled) == .notOnScreen)
    }

    @Test("a permission with nothing to tell it from another is never answered")
    func noFragment() throws {
        let bare = try Self.request([#"{"hook_event_name":"PermissionRequest","tool_name":"Mystery","tool_input":{}}"#,
                                     ClaudePendingFixtures.permissionPrompt])
        #expect(ClaudeDialogAnswer.check(bare, screen: Self.stackedScreen) == .notOnScreen)
    }
}
