import SwiftUI
import ScopeCore

/// Markdown laid out as native views: one view per `MarkdownBlock`, inline syntax through `AttributedString`.
///
/// Native rather than a web view: the text is an agent's, so nothing in it may load or run, and the chrome has to be
/// the app's own — the Theme tokens, SF, the terminal's mono font — in light and dark alike. A code span that reads
/// as a file path becomes a link the host resolves like a terminal link (`MarkdownLink.pathLink`).
struct MarkdownReader: View {
    let document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownBlocks(blocks: document.blocks)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The blocks of a document, a list item or a quote, with the space between them.
struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// Tighter inside a list item.
    var compact = false

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            MarkdownBlockView(block: block)
                .padding(.top, index == 0 ? 0 : spacing(before: block, after: blocks[index - 1]))
        }
    }

    private func spacing(before block: MarkdownBlock, after previous: MarkdownBlock) -> CGFloat {
        if case .heading = block { return compact ? 10 : 18 }
        if case .heading = previous { return 6 }
        return compact ? 6 : 12
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownInlineText(text, font: Self.headingFont(level))
                .foregroundStyle(Ink.primary)
                .padding(.bottom, level <= 2 ? 6 : 0)
                .overlay(alignment: .bottom) {
                    if level <= 2 { Rectangle().fill(Surface.stroke).frame(height: 1) }
                }
        case .paragraph(let text):
            MarkdownInlineText(text, font: Self.bodyFont)
                .foregroundStyle(Ink.primary)
        case .code(let language, let text):
            MarkdownCodeBlock(language: language, text: text)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Surface.stroke)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownBlocks(blocks: blocks, compact: true)
                }
                .foregroundStyle(Ink.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            MarkdownListView(list: list)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle().fill(Surface.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    static let bodyFont = Font.system(size: 13)
    static let bodyLineSpacing: CGFloat = 3

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 20, weight: .semibold)
        case 2: .system(size: 16, weight: .semibold)
        case 3: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
        }
    }
}

/// One line of inline Markdown: emphasis, code spans, links. Links keep their destination for the host's
/// `openURL`; a code span naming a path gets one.
struct MarkdownInlineText: View {
    let text: String
    let font: Font

    init(_ text: String, font: Font = MarkdownBlockView.bodyFont) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(Self.attributed(text, font: font))
            .font(font)
            .lineSpacing(MarkdownBlockView.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Code spans in the terminal's font on a quiet fill, links in the accent; everything else as the block set it.
    static func attributed(_ text: String, font: Font) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in result.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                result[range].font = .system(size: 12, design: .monospaced)
                result[range].backgroundColor = Fill.quiet
                if run.link == nil, let path = MarkdownLink.pathLink(forCode: String(result[range].characters)) {
                    result[range].link = path
                    result[range].underlineStyle = .single
                    result[range].underlineColor = NSColor(Ink.tertiary)
                }
            }
            if let link = run.link {
                // A link whose destination will not be followed looks like text, not like a promise.
                if case .refused = MarkdownLink.classify(link.absoluteString) {
                    result[range].link = nil
                } else {
                    result[range].foregroundColor = .accentColor
                }
            }
            // An image is a link the reader will not fetch: its alt text, as a link to the file or the page.
            if let image = run.imageURL {
                result[range].imageURL = nil
                if case .refused = MarkdownLink.classify(image.absoluteString) {} else {
                    result[range].link = image
                    result[range].foregroundColor = .accentColor
                }
            }
        }
        return result
    }
}

struct MarkdownCodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language ?? "code")
                    .font(.scopeMicro)
                    .foregroundStyle(Ink.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                CopyButton(label: "Copy the code") { text }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 24)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke))
    }
}

struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    marker(index, item)
                        .font(MarkdownBlockView.bodyFont)
                        .foregroundStyle(Ink.secondary)
                        .frame(width: list.ordered ? 26 : 18, alignment: list.ordered ? .trailing : .center)
                        .padding(.trailing, 6)
                    VStack(alignment: .leading, spacing: 0) {
                        MarkdownBlocks(blocks: item.blocks, compact: true)
                    }
                    .foregroundStyle(item.checked == true ? Ink.tertiary : Ink.primary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func marker(_ index: Int, _ item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(checked ? ThreadStateStyle.done : Ink.tertiary)
        } else if list.ordered {
            Text("\(list.start + index).")
                .monospacedDigit()
        } else {
            Text("•")
        }
    }
}

/// A table on a `Grid`: the header on a quiet fill, a hairline between rows, columns aligned as the delimiter row
/// said. Cells wrap; a table wider than the column scrolls sideways rather than squeezing its columns to nothing.
struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column, font: .system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .background(Surface.panel)
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column, font: .system(size: 12.5))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke))
        }
    }

    private func cell(_ text: String, column: Int, font: Font) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return MarkdownInlineText(text, font: font)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: 360, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}
