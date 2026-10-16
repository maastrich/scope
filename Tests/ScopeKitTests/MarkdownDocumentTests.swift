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

    @Test func htmlBlocksAndContainersAreKeptRawNotReadAsParagraphs() {
        let parsed = blocks("""
        Before.

        <details><summary>Benchmarks</summary>
        | run | ms |
        </details>

        :::callout{kind="tip"}
        Inside the container.
        :::
        After, with a < b in a sentence.
        """)
        #expect(parsed == [
            .paragraph("Before."),
            .raw("<details><summary>Benchmarks</summary>\n| run | ms |\n</details>"),
            .raw(":::callout{kind=\"tip\"}\nInside the container.\n:::"),
            .paragraph("After, with a < b in a sentence."),
        ])
        // A tag in the middle of a paragraph is inline text, as before: only a line opening on one is raw.
        #expect(blocks("A <b>bold</b> word.") == [.paragraph("A <b>bold</b> word.")])
        #expect(MarkdownDocument.parse("<!-- note -->\nx").plainText == "<!-- note -->\nx")
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

    /// The release table that drew its rows over each other in the reader (v0.23.0): a short labels column, a
    /// long prose column, inline bold and code in the cells. The parser hands the view every cell whole.
    @Test func aTableWithLongProseCells() {
        let text = """
        | Release | Contenu |
        |---|---|
        | **v0.21.0** (vague 0+1) | restore pour les agents + actions de task dans ⌘K · capture de l'activité des threads · notifications avec extrait et réponse · ligne d'activité dans la sidebar + arbre de délégation · « Demander à l'orchestrateur » + réponse inline · PR rafraîchies en arrière-plan |
        | **v0.22.0** (vague 2) | faux « waiting » en mode auto · thread fini mais « running » · compteur de tokens (5 h / 7 j) · lecture Markdown de la réponse + livrable gardé à l'archivage + brief visible |
        | **v0.23.0** (vague 3) | modèle par task/thread + `thread.send --command` · rebase auto quand `main` avance · raccourci global ⌥Space (Ask / Inbox) |
        """
        guard case .table(let table)? = blocks(text).first, blocks(text).count == 1 else {
            Issue.record("expected one table")
            return
        }
        #expect(table.header == ["Release", "Contenu"])
        #expect(table.alignments == [.leading, .leading])
        #expect(table.rows.count == 3)
        #expect(table.rows.map(\.count) == [2, 2, 2])
        #expect(table.rows[0][0] == "**v0.21.0** (vague 0+1)")
        #expect(table.rows[0][1].hasPrefix("restore pour les agents"))
        #expect(table.rows[0][1].hasSuffix("PR rafraîchies en arrière-plan"))
        #expect(table.rows[0][1].count > 250)
        #expect(table.rows[2][1] == "modèle par task/thread + `thread.send --command` · rebase auto quand `main` avance · raccourci global ⌥Space (Ask / Inbox)")
    }

    @Test func aWideTableKeepsEveryColumn() {
        let header = (1...8).map { "Col \($0)" }
        let text = "| " + header.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 8) + "\n| "
            + (1...8).map { "cell \($0) with some words" }.joined(separator: " | ") + " |"
        guard case .table(let table)? = blocks(text).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == header)
        #expect(table.rows == [(1...8).map { "cell \($0) with some words" }])
    }

    @Test func longUnbrokenWordsStayInTheirParagraph() {
        let path = "/Users/me/.scope/sandboxes/very/deep/path/to/App/Scope/Views/Inspector/Reading/MarkdownReader.swift"
        let url = "https://github.com/maastrich/scope/pull/54/files#diff-0123456789abcdef0123456789abcdef0123456789abcdef"
        #expect(blocks("See `\(path)`\nand \(url) here.") == [.paragraph("See `\(path)` and \(url) here.")])
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
        // Raw, shown verbatim; never a paragraph that hides the tags in prose, never interpreted.
        #expect(blocks("<script>alert(1)</script>") == [.raw("<script>alert(1)</script>")])
        #expect(blocks("Run <script>alert(1)</script> here") == [.paragraph("Run <script>alert(1)</script> here")])
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
        for path in ["Sources/App.swift:12", "README.md", "package.json", "Makefile.toml", "./scripts/build.sh", "/tmp/x.log", "Sources/ScopeCore", "~/notes.md"] {
            let url = MarkdownLink.pathLink(forCode: path)
            #expect(url != nil, "\(path)")
            #expect(url.map { MarkdownLink.classify($0.absoluteString) } == .file(path), "\(path)")
        }
    }

    @Test func codeIsNotAPath() {
        for code in ["foo.bar()", "x = 1", "v1.2.3", "--flag", "ThreadActivity.replyLimit", "swift test",
                     "https://x.dev/a.md", "localhost:3000", "$HOME/x", "TaskRecord.snapshot", "CacheKey.make", "Array.first"] {
            #expect(MarkdownLink.pathLink(forCode: code) == nil, "\(code)")
        }
    }
}
