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

/// A table whose columns share the reading width: a cell wraps inside its column, a row is as tall as its tallest
/// cell, a short column keeps its width and a long one takes the rest (`MarkdownTableLayout`). A table whose columns
/// cannot all fit, even wrapped, scrolls sideways in its own container rather than squeezing them to nothing.
///
/// Not a `Grid`: inside a horizontal `ScrollView` a `Grid` measures every cell at its one-line width, then clamps the
/// frame — the text wrapped into a row sized for one line, and the rows drew over each other.
struct MarkdownTableView: View {
    let table: MarkdownTable
    /// The width the table may take before it scrolls: the scroll view's own, read once laid out.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            MarkdownTableLayout(columns: table.header.count, availableWidth: availableWidth) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, font: .system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .background(Surface.panel)
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, font: .system(size: 12.5))
                            .overlay(alignment: .top) { Rectangle().fill(Surface.stroke).frame(height: 1) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func cell(_ text: String, column: Int, font: Font) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return MarkdownInlineText(text, font: font)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment == .center ? .top : alignment == .trailing ? .topTrailing : .topLeading)
    }
}

/// The cells of a table, row-major, laid out on shared columns — a browser's automatic table layout, in short.
///
/// Every column is measured at its one-line width (its *ideal*). When they all fit in `availableWidth`, each takes
/// its ideal and the table stays as narrow as its content. Otherwise the columns narrow enough to fit a fair share
/// keep their ideal, and the others split what is left in proportion to their ideal, down to a floor below which a
/// column wraps too badly to read; past the floor the table is wider than the view and scrolls. Row heights are
/// measured at the final column widths, so wrapped text never runs into the next row.
struct MarkdownTableLayout: Layout {
    let columns: Int
    /// `0` before the first layout pass: columns then take their ideal, capped so a long cell still wraps.
    let availableWidth: CGFloat

    static let minColumnWidth: CGFloat = 96
    static let maxUnmeasuredColumnWidth: CGFloat = 360

    struct Cache {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var measuredFor: CGFloat = -1
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(subviews, &cache)
        return CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(subviews, &cache)
        var y = bounds.minY
        for row in cache.heights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let size = CGSize(width: cache.widths[column], height: cache.heights[row])
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width
            }
            y += cache.heights[row]
        }
    }

    private func measure(_ subviews: Subviews, _ cache: inout Cache) {
        guard columns > 0, cache.measuredFor != availableWidth || cache.widths.count != columns else { return }
        var ideal = [CGFloat](repeating: 0, count: columns)
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            ideal[column] = max(ideal[column], subview.sizeThatFits(.unspecified).width.rounded(.up))
        }
        cache.widths = Self.distribute(ideal: ideal, in: availableWidth)
        let rows = (subviews.count + columns - 1) / columns
        cache.heights = (0..<rows).map { row in
            (0..<columns).reduce(CGFloat(0)) { height, column in
                let index = row * columns + column
                guard index < subviews.count else { return height }
                let proposal = ProposedViewSize(width: cache.widths[column], height: nil)
                return max(height, subviews[index].sizeThatFits(proposal).height.rounded(.up))
            }
        }
        cache.measuredFor = availableWidth
    }

    /// Column widths for `ideal` one-line widths in `available` points; `0` when the width is not known yet.
    static func distribute(ideal: [CGFloat], in available: CGFloat) -> [CGFloat] {
        guard available > 0 else { return ideal.map { min($0, maxUnmeasuredColumnWidth) } }
        guard ideal.reduce(0, +) > available else { return ideal }
        var widths = ideal
        var remaining = available
        var flexible = Set(ideal.indices)
        // A column narrower than an equal share keeps its width: the labels column stays one line.
        while true {
            let share = remaining / CGFloat(flexible.count)
            let settled = flexible.filter { ideal[$0] <= share }
            if settled.isEmpty { break }
            for column in settled {
                remaining -= ideal[column]
                flexible.remove(column)
            }
            if flexible.isEmpty { return widths }
        }
        let total = flexible.reduce(CGFloat(0)) { $0 + ideal[$1] }
        for column in flexible {
            widths[column] = max(min(minColumnWidth, ideal[column]), (remaining * ideal[column] / total).rounded(.down))
        }
        return widths
    }
}
