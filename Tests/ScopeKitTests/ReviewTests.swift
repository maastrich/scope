import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite struct ReviewTests {
    /// `func a() {` … a small file whose line `n` reads `line n` unless replaced.
    private static let file = [
        "import Foundation",         // 1
        "",                          // 2
        "func login() {",            // 3
        "    let token = fetch()",   // 4
        "    save(token)",           // 5
        "}",                         // 6
        "",                          // 7
        "func logout() {",           // 8
        "    clear()",               // 9
        "}",                         // 10
    ]

    private static func side(_ lines: [String]) -> [(number: Int, text: String)] {
        lines.enumerated().map { ($0.offset + 1, $0.element) }
    }

    private static func anchor(_ start: Int, _ end: Int, in lines: [String] = file) -> ReviewAnchor {
        ReviewAnchor.make(side: side(lines), start: start - 1, end: end - 1)
    }

    @Test func anAnchorKeepsItsLinesAndThreeOfContext() {
        let anchor = Self.anchor(4, 5)
        #expect(anchor.line == 4 && anchor.span == 2)
        #expect(anchor.lines == ["    let token = fetch()", "    save(token)"])
        #expect(anchor.before == ["import Foundation", "", "func login() {"])
        #expect(anchor.after == ["}", "", "func logout() {"])
        // Reversed ranges and the edges of the file.
        #expect(Self.anchor(5, 4) == anchor)
        #expect(Self.anchor(1, 1).before.isEmpty && Self.anchor(10, 10).after.isEmpty)
    }

    @Test func theAnchorFollowsItsLinesWhenTheFileMoves() {
        let anchor = Self.anchor(4, 5)
        #expect(anchor.locate(in: Self.file) == 4)
        let shifted = ["// header", "// more", "// and more"] + Self.file
        #expect(anchor.locate(in: shifted) == 7)
    }

    @Test func aTieGoesToTheOldLineAndACommonLineNeedsContext() {
        // Two identical `}` lines: the one with the same surroundings wins, not the first.
        let brace = Self.anchor(10, 10)
        #expect(brace.locate(in: Self.file) == 10)
        // Nothing around it matches anymore: a lone `}` is not the same place.
        #expect(brace.locate(in: ["struct A {", "  var b = 1", "}", "", "struct C {", "}"]) == nil)
        // A distinctive line found once is kept even with its surroundings rewritten.
        let token = Self.anchor(4, 4)
        #expect(token.locate(in: ["x", "y", "    let token = fetch()", "z"]) == 3)
        #expect(token.locate(in: ["nothing", "here"]) == nil)
    }

    @Test func theReviewShowsCurrentNumbersAndTheComment() {
        let comment = ReviewComment(repo: "api", path: "Sources/Auth.swift", side: .new, anchor: Self.anchor(4, 5),
                                    body: "  Handle a failed fetch.\n")
        let moved = ["// one", "// two"] + Self.file
        let text = ReviewRenderer.render([comment], repoName: { $0 }, currentFile: { _ in moved })
        #expect(text == """
        Review of your changes — 1 comment. Address each one, then say what you changed.

        ## api/Sources/Auth.swift, lines 6–7
        ```
          4
          5  func login() {
        > 6      let token = fetch()
        > 7      save(token)
          8  }
          9
        ```
        Handle a failed fetch.

        """)
    }

    @Test func aLostAnchorFallsBackToTheSnapshotAndSaysSo() {
        let comment = ReviewComment(repo: "api", path: "a.swift", side: .new, anchor: Self.anchor(4, 4), body: "why?")
        let gone = ReviewRenderer.render([comment], repoName: { _ in "Acme" }, currentFile: { _ in nil })
        #expect(gone.contains("## Acme/a.swift, line 4\n(The file is gone; this is the code as it was when commented.)\n```\n> 4      let token = fetch()\n```\nwhy?"))
        let changed = ReviewRenderer.render([comment], repoName: { $0 }, currentFile: { _ in ["rewritten"] })
        #expect(changed.contains("(These lines changed since"))
        // The old side is the base: shown as stored, never looked up.
        var removed = comment
        removed.side = .old
        let old = ReviewRenderer.render([removed], repoName: { $0 }, currentFile: { _ in Issue.record("looked up"); return nil })
        #expect(old.contains("line 4 (removed lines, before the change)\n```"))
    }

    @Test func theReviewIsCappedAndOrderedByFileAndLine() {
        let many = (1...65).map { index in
            ReviewComment(repo: "api", path: "f.swift", side: .old,
                          anchor: ReviewAnchor(line: 66 - index, span: 1, lines: ["x"], before: [], after: []), body: "c\(index)")
        }
        let text = ReviewRenderer.render(many, repoName: { $0 }, currentFile: { _ in nil })
        #expect(text.hasPrefix("Review of your changes — 60 comments."))
        #expect(text.contains("(5 more comments were not included.)"))
        #expect(text.range(of: "line 1 ")!.lowerBound < text.range(of: "line 2 ")!.lowerBound)
    }

    @Test func aPasteIsOneEnvelopeThatCannotBeClosedEarly() {
        #expect(ThreadDelivery.bracketedPaste("a\nb") == "\u{1b}[200~a\nb\u{1b}[201~")
        #expect(ThreadDelivery.bracketedPaste("x\u{1b}[201~rm -rf /") == "\u{1b}[200~xrm -rf /\u{1b}[201~")
    }

    @Test func aThreadTakesTheReviewOnlyBetweenTurns() {
        #expect(!ThreadDelivery.canDeliver(to: .running))
        #expect(!ThreadDelivery.canDeliver(to: .exited))
        for state in [ThreadState.idle, .done, .waiting(reason: .input), .waiting(reason: .permission)] {
            #expect(ThreadDelivery.canDeliver(to: state))
        }
    }

    /// A thread whose hooks never reported has no turn to wait for: holding the review would hold it forever.
    @Test func aThreadWithoutHookReportsTakesItAtOnce() {
        #expect(ThreadDelivery.canDeliver(reported: nil, alive: true))
        #expect(!ThreadDelivery.canDeliver(reported: nil, alive: false))
        #expect(!ThreadDelivery.canDeliver(reported: .running, alive: true))
        #expect(ThreadDelivery.canDeliver(reported: .done, alive: true))
    }

    @Test func commentsAreKeptPerTaskUnderTheHome() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ReviewStore(home: home)
        let task = TaskID.generate()
        let comment = ReviewComment(repo: ".", path: "a", side: .new, anchor: Self.anchor(3, 3), body: "b",
                                    createdAt: TaskRecord.roundedToMilliseconds(.now))
        #expect(await store.load(task).isEmpty)
        try await store.save([comment], for: task)
        #expect(store.url(for: task).path.hasPrefix(home.path))
        #expect(await store.load(task) == [comment])
        try await store.save([], for: task)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: task).path))
    }
}

@Suite struct ReviewPlacementTests {
    /// `-a` removed, `+b` `+c` added, context around: old 1..3 / new 1..4.
    private static let lines: [DiffLine] = [
        DiffLine(kind: .context, text: "start", oldLineNumber: 1, newLineNumber: 1),
        DiffLine(kind: .deletion, text: "a", oldLineNumber: 2),
        DiffLine(kind: .addition, text: "b", newLineNumber: 2),
        DiffLine(kind: .addition, text: "c", newLineNumber: 3),
        DiffLine(kind: .context, text: "end", oldLineNumber: 3, newLineNumber: 4),
    ]

    @Test func aSelectionTakesTheSideOfItsFirstLine() throws {
        let added = try #require(ReviewPlacement.anchor(for: Self.lines, start: 2, end: 3))
        #expect(added.side == .new && added.anchor.line == 2 && added.anchor.lines == ["b", "c"])
        #expect(added.anchor.before == ["start"] && added.anchor.after == ["end"])
        // Starting on a removed line: the old side, the added lines inside skipped.
        let removed = try #require(ReviewPlacement.anchor(for: Self.lines, start: 1, end: 4))
        #expect(removed.side == .old && removed.anchor.line == 2 && removed.anchor.lines == ["a", "end"])
        #expect(ReviewPlacement.anchor(for: Self.lines, start: 9, end: 9) == nil)
    }

    @Test func commentsHangUnderTheirLastLineOrAreOrphans() throws {
        let (side, anchor) = try #require(ReviewPlacement.anchor(for: Self.lines, start: 2, end: 3))
        let here = ReviewComment(repo: "api", path: "f", side: side, anchor: anchor, body: "x")
        let gone = ReviewComment(repo: "api", path: "f", side: .new,
                                 anchor: ReviewAnchor(line: 9, span: 1, lines: ["nowhere"], before: [], after: []), body: "y")
        let placement = ReviewPlacement.place([here, gone], in: Self.lines)
        #expect(placement.placed == [3: [here]])
        #expect(placement.orphans == [gone])
    }
}
