import Foundation
import Testing
@testable import ScopeCore

@Suite struct MarkdownDocumentTests {
    private func blocks(_ text: String) -> [MarkdownBlock] {
        MarkdownDocument.parse(text).blocks
    }

    @Test func headingsParagraphsAndRules() {
        let parsed = blocks("""
        # Title #

        First line
        goes on.

        ---
        ## Second
        Setext
        ======
        """)
        #expect(parsed == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line goes on."),
            .rule,
            .heading(level: 2, text: "Second"),
            .heading(level: 1, text: "Setext"),
        ])
    }

    @Test func hardBreaksStayLineBreaks() {
        #expect(blocks("one  \ntwo\\\nthree") == [.paragraph("one\ntwo\nthree")])
    }

    @Test func aHashWithoutASpaceIsText() {
        #expect(blocks("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func fencedCodeIsVerbatim() {
        let parsed = blocks("""
        Before:
        ```swift
        let a = 1
            # not a heading
        | not | a table |
        ```
        After.
        """)
        #expect(parsed == [
            .paragraph("Before:"),
            .code(language: "swift", text: "let a = 1\n    # not a heading\n| not | a table |"),
            .paragraph("After."),
        ])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(blocks("~~~\nopen") == [.code(language: nil, text: "open")])
    }

    @Test func aReplyCutInsideAFenceDoesNotSwallowTheRest() {
        // `ThreadActivity.bounded` keeps the end of a long answer: here, the end of a code block and the conclusion.
        let parsed = blocks("…return value\n}\n```\n\n## Conclusion\n\nIt works.")
        #expect(parsed == [
            .code(language: nil, text: "…return value\n}"),
            .heading(level: 2, text: "Conclusion"),
            .paragraph("It works."),
        ])
        // The same start with balanced fences is not code.
        #expect(blocks("…the end.\n```\nx\n```") == [.paragraph("…the end."), .code(language: nil, text: "x")])
    }

    @Test func tables() {
        let parsed = blocks("""
        | Idea | Status | Cost |
        |:-----|:------:|-----:|
        | E2 | done | `a|b` |
        | C2 \\| bis | open |
        """)
        #expect(parsed == [.table(MarkdownTable(
            header: ["Idea", "Status", "Cost"],
            alignments: [.leading, .center, .trailing],
            rows: [["E2", "done", "`a|b`"], ["C2 | bis", "open", ""]]
        ))])
    }

    @Test func aTableRightUnderAParagraph() {
        let parsed = blocks("Results:\na | b\n--- | ---\n1 | 2\n\nafter")
        #expect(parsed == [
            .paragraph("Results:"),
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])),
            .paragraph("after"),
        ])
    }

    @Test func aPipeWithoutADelimiterRowIsText() {
        #expect(blocks("a | b\nc | d") == [.paragraph("a | b c | d")])
    }

    @Test func nestedListsAndTaskItems() {
        let parsed = blocks("""
        - one
          continued
        - two
          1. sub a
          2. sub b
        - [x] done
        - [ ] todo

        3. three
        4. four
        """)
        #expect(parsed == [
            .list(MarkdownList(ordered: false, items: [
                .init(blocks: [.paragraph("one continued")]),
                .init(blocks: [.paragraph("two"), .list(MarkdownList(ordered: true, items: [
                    .init(blocks: [.paragraph("sub a")]),
                    .init(blocks: [.paragraph("sub b")]),
                ]))]),
                .init(checked: true, blocks: [.paragraph("done")]),
                .init(checked: false, blocks: [.paragraph("todo")]),
            ])),
            .list(MarkdownList(ordered: true, start: 3, items: [
                .init(blocks: [.paragraph("three")]),
                .init(blocks: [.paragraph("four")]),
            ])),
        ])
    }

    @Test func aListItemHoldsCode() {
        let parsed = blocks("1. Run:\n   ```sh\n   swift test\n   ```\n2. Read.")
        #expect(parsed == [.list(MarkdownList(ordered: true, items: [
            .init(blocks: [.paragraph("Run:"), .code(language: "sh", text: "swift test")]),
            .init(blocks: [.paragraph("Read.")]),
        ]))])
    }

    @Test func aNumberInASentenceDoesNotStartAList() {
        #expect(blocks("We shipped in\n2024. Then more.") == [.paragraph("We shipped in 2024. Then more.")])
    }

    @Test func boldAtTheStartOfALineIsNotABullet() {
        #expect(blocks("**Bold** start") == [.paragraph("**Bold** start")])
    }

    @Test func quotes() {
        let parsed = blocks("> # Note\n> quoted\nlazy\n\nout")
        #expect(parsed == [
            .quote([.heading(level: 1, text: "Note"), .paragraph("quoted lazy")]),
            .paragraph("out"),
        ])
    }

    @Test func htmlIsText() {
        #expect(blocks("<script>alert(1)</script>") == [.paragraph("<script>alert(1)</script>")])
    }
}

@Suite struct MarkdownLinkTests {
    @Test func webLinksOpenInTheBrowser() {
        #expect(MarkdownLink.classify("https://github.com/a/b") == .web(URL(string: "https://github.com/a/b")!))
        #expect(MarkdownLink.classify("mailto:a@b.c") == .web(URL(string: "mailto:a@b.c")!))
    }

    @Test func unsafeSchemesAreRefused() {
        for link in ["javascript:alert(1)", "data:text/html,x", "vscode://file/x", "http:nohost", "#anchor", ""] {
            #expect(MarkdownLink.classify(link) == .refused, "\(link)")
        }
    }

    @Test func pathsAreFiles() {
        #expect(MarkdownLink.classify("Sources/App.swift") == .file("Sources/App.swift"))
        #expect(MarkdownLink.classify("Sources/App.swift#L12") == .file("Sources/App.swift:12"))
        #expect(MarkdownLink.classify("README.md:3") == .file("README.md:3"))
        #expect(MarkdownLink.classify("file:///tmp/a.md") == .file("file:///tmp/a.md"))
        #expect(MarkdownLink.classify("docs/a%20b.md") == .file("docs/a b.md"))
    }

    @Test func codeSpansThatNamePathsBecomeLinks() {
        for path in ["Sources/App.swift:12", "README.md", "./scripts/build.sh", "/tmp/x.log", "Sources/ScopeCore", "~/notes.md"] {
            let url = MarkdownLink.pathLink(forCode: path)
            #expect(url != nil, "\(path)")
            #expect(url.map { MarkdownLink.classify($0.absoluteString) } == .file(path), "\(path)")
        }
    }

    @Test func codeIsNotAPath() {
        for code in ["foo.bar()", "x = 1", "v1.2.3", "--flag", "ThreadActivity.replyLimit", "swift test",
                     "https://x.dev/a.md", "localhost:3000", "$HOME/x", "TaskRecord.snapshot"] {
            #expect(MarkdownLink.pathLink(forCode: code) == nil, "\(code)")
        }
    }
}
