import Foundation

/// An agent's answer, a task's brief or a report, cut into the blocks a reading view lays out: headings, paragraphs,
/// lists, tables, fenced code, quotes and rules.
///
/// The block structure only. Inline syntax (emphasis, code spans, links) stays in each block's text, as Markdown,
/// for the view to style (`AttributedString(markdown:)` handles inline syntax well; it is tables, lists and fences it
/// cannot do). Nothing here is HTML: a raw tag is text, an image is a link, nothing is ever fetched.
///
/// A CommonMark subset, the part agents write. Indented code blocks are not one (a nested list's content is indented
/// too, and agents fence their code); a setext heading is.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ text: String) -> MarkdownDocument {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\t", with: "    ") }
        // A reply kept from its end (`ThreadActivity.bounded`) starts with `…` and may have been cut inside a fence:
        // its first fence is then a closing one, and read as an opening one it would swallow the rest of the answer.
        if text.hasPrefix("…"), lines.filter({ Fence.opening($0) != nil }).count % 2 == 1 {
            lines.insert("```", at: 0)
        }
        var parser = BlockParser(lines: lines)
        return MarkdownDocument(blocks: parser.parseBlocks())
    }

    /// The text of every block, without Markdown structure: what a search or an excerpt reads.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    /// Level 1…6; the text holds inline Markdown.
    case heading(level: Int, text: String)
    /// Inline Markdown; `\n` is a hard line break, soft breaks are already spaces.
    case paragraph(String)
    /// Fenced code, verbatim. `language` is the info string's first word.
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case rule

    var plainText: String {
        switch self {
        case .heading(_, let text), .paragraph(let text), .code(_, let text): text
        case .quote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .list(let list): list.items.flatMap(\.blocks).map(\.plainText).joined(separator: "\n")
        case .table(let table): ([table.header] + table.rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
        case .rule: ""
        }
    }
}

public struct MarkdownList: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// `true` / `false` for a task list item (`- [x]`, `- [ ]`), `nil` otherwise.
        public var checked: Bool?
        public var blocks: [MarkdownBlock]

        public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
            self.checked = checked
            self.blocks = blocks
        }
    }

    public var ordered: Bool
    /// The first item's number, for an ordered list.
    public var start: Int
    public var items: [Item]

    public init(ordered: Bool, start: Int = 1, items: [Item]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case leading, center, trailing
    }

    /// Inline Markdown per cell.
    public var header: [String]
    public var alignments: [Alignment]
    /// Every row has `header.count` cells: short rows are padded, long ones cut, as GitHub does.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// The cells of a row, split on the pipes that are not escaped nor inside a code span.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var codeTicks = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                // `\|` is a pipe in the cell; any other escape stays for the inline parser.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                var run = 0
                while index < text.endIndex, text[index] == "`" {
                    run += 1
                    index = text.index(after: index)
                }
                current += String(repeating: "`", count: run)
                codeTicks = codeTicks == 0 ? run : (codeTicks == run ? 0 : codeTicks)
                continue
            } else if character == "|", codeTicks == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The alignments a delimiter row (`| :--- | ---: |`) declares, `nil` when the line is not one.
    static func delimiter(_ line: String) -> [Alignment]? {
        guard line.contains("-") else { return nil }
        let cells = cells(line)
        var alignments: [Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
    }
}

/// A fence line: three or more backticks or tildes, indented by three spaces at most.
enum Fence {
    struct Marker {
        var character: Character
        var count: Int
        var indent: Int
        var info: String
    }

    static func opening(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let count = rest.prefix { $0 == character }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string cannot hold a backtick: that line is inline code.
        if character == "`", info.contains("`") { return nil }
        return Marker(character: character, count: count, indent: indent, info: info)
    }

    static func closes(_ line: String, _ marker: Marker) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let count = rest.prefix { $0 == marker.character }.count
        return count >= marker.count && rest.dropFirst(count).allSatisfy(\.isWhitespace)
    }
}

/// A list item's marker: `-`, `*`, `+`, `1.` or `1)`, and where its content starts.
struct ListMarker {
    var ordered: Bool
    /// The bullet character or the ordered delimiter: a different one starts a new list.
    var delimiter: Character
    var number: Int
    var indent: Int
    /// Column the item's content starts at; continuation lines indented this far belong to it.
    var contentIndent: Int
    var content: String

    static func parse(_ line: String) -> ListMarker? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        var markerWidth: Int
        var ordered = false
        var delimiter = first
        var number = 1
        if "-*+".contains(first) {
            markerWidth = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let after = rest.dropFirst(digits.count).first, after == "." || after == ")" else { return nil }
            ordered = true
            delimiter = after
            number = Int(digits) ?? 1
            markerWidth = digits.count + 1
        }
        let afterMarker = rest.dropFirst(markerWidth)
        let spaces = afterMarker.prefix { $0 == " " }.count
        // `-foo` is not an item; `-` alone is an empty one.
        guard spaces > 0 || afterMarker.isEmpty else { return nil }
        // Five spaces or more after the marker: one of them is the separator, the rest is content.
        let gap = spaces > 4 ? 1 : max(spaces, 1)
        return ListMarker(ordered: ordered, delimiter: delimiter, number: number, indent: indent,
                          contentIndent: indent + markerWidth + gap,
                          content: String(afterMarker.dropFirst(min(spaces, gap))))
    }
}

struct BlockParser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            if line.allSatisfy(\.isWhitespace) {
                index += 1
            } else if let fence = Fence.opening(line) {
                blocks.append(code(fence))
            } else if let heading = Self.atxHeading(line) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if Self.isQuote(line) {
                blocks.append(quote())
            } else if let marker = ListMarker.parse(line), marker.indent <= 3 {
                blocks.append(list(marker))
            } else if let table = table() {
                blocks.append(table)
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    // MARK: Blocks

    private mutating func code(_ fence: Fence.Marker) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count, !Fence.closes(lines[index], fence) {
            // Content keeps its indentation, less the fence's own.
            let line = lines[index]
            let strip = min(fence.indent, line.prefix { $0 == " " }.count)
            body.append(String(line.dropFirst(strip)))
            index += 1
        }
        index += 1   // the closing fence, or past the end
        let language = fence.info.split(separator: " ").first.map(String.init)
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    private mutating func quote() -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let line = lines[index]
            if Self.isQuote(line) {
                var stripped = line.drop { $0 == " " }.dropFirst()
                if stripped.first == " " { stripped = stripped.dropFirst() }
                inner.append(String(stripped))
            } else if !line.allSatisfy(\.isWhitespace), let last = inner.last, !last.allSatisfy(\.isWhitespace),
                      !Self.interrupts(line) {
                inner.append(line)   // lazy continuation of the quoted paragraph
            } else {
                break
            }
            index += 1
        }
        var parser = BlockParser(lines: inner)
        return .quote(parser.parseBlocks())
    }

    private mutating func list(_ first: ListMarker) -> MarkdownBlock {
        var items: [MarkdownList.Item] = []
        var marker = first
        while true {
            index += 1
            var body = [marker.content]
            var sawBlank = false
            while index < lines.count {
                let line = lines[index]
                if line.allSatisfy(\.isWhitespace) {
                    sawBlank = true
                    body.append("")
                    index += 1
                    continue
                }
                let indent = line.prefix { $0 == " " }.count
                if indent >= marker.contentIndent {
                    body.append(String(line.dropFirst(marker.contentIndent)))
                    sawBlank = false
                    index += 1
                } else if !sawBlank, ListMarker.parse(line) == nil, !Self.interrupts(line),
                          let last = body.last, !last.allSatisfy(\.isWhitespace), !Self.endsInCode(body) {
                    body.append(line.trimmingCharacters(in: .whitespaces))   // lazy continuation
                    index += 1
                } else {
                    break
                }
            }
            while body.last?.allSatisfy(\.isWhitespace) == true { body.removeLast() }
            var checked: Bool?
            if let first = body.first, let box = Self.taskBox(first) {
                checked = box.checked
                body[0] = box.rest
            }
            var parser = BlockParser(lines: body)
            items.append(MarkdownList.Item(checked: checked, blocks: parser.parseBlocks()))

            guard index < lines.count, let next = ListMarker.parse(lines[index]),
                  next.ordered == first.ordered, next.delimiter == first.delimiter,
                  next.indent < first.contentIndent else { break }
            marker = next
        }
        return .list(MarkdownList(ordered: first.ordered, start: first.number, items: items))
    }

    private mutating func table() -> MarkdownBlock? {
        guard index + 1 < lines.count, lines[index].contains("|"),
              let alignments = MarkdownTable.delimiter(lines[index + 1]) else { return nil }
        let header = MarkdownTable.cells(lines[index])
        guard header.count == alignments.count else { return nil }
        index += 2
        var rows: [[String]] = []
        while index < lines.count, !lines[index].allSatisfy(\.isWhitespace), lines[index].contains("|"),
              Fence.opening(lines[index]) == nil {
            var row = MarkdownTable.cells(lines[index])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        return .table(MarkdownTable(header: header, alignments: alignments, rows: rows))
    }

    private mutating func paragraph() -> MarkdownBlock {
        var collected: [String] = [lines[index]]
        index += 1
        while index < lines.count {
            let line = lines[index]
            if line.allSatisfy(\.isWhitespace) { break }
            // Setext underline: the paragraph so far is a heading.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.prefix(while: { $0 == " " }).count <= 3, !trimmed.isEmpty {
                if trimmed.allSatisfy({ $0 == "=" }) {
                    index += 1
                    return .heading(level: 1, text: Self.join(collected))
                }
                if trimmed.allSatisfy({ $0 == "-" }) {
                    index += 1
                    return .heading(level: 2, text: Self.join(collected))
                }
            }
            if Self.interrupts(line) { break }
            // A table may start right under a paragraph line only when it is a table, header and delimiter.
            if line.contains("|"), index + 1 < lines.count, MarkdownTable.delimiter(lines[index + 1]) != nil { break }
            collected.append(line)
            index += 1
        }
        return .paragraph(Self.join(collected))
    }

    // MARK: Line kinds

    static func atxHeading(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of `#` goes when a space separates it from the text.
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: text)
    }

    static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isQuote(_ line: String) -> Bool {
        line.prefix(while: { $0 == " " }).count <= 3 && line.drop { $0 == " " }.first == ">"
    }

    /// A line that ends a paragraph without a blank line before it.
    static func interrupts(_ line: String) -> Bool {
        if Fence.opening(line) != nil || atxHeading(line) != nil || isRule(line) || isQuote(line) { return true }
        // Only a list that cannot be a number in a sentence: a bullet, or an ordered list starting at 1.
        if let marker = ListMarker.parse(line), marker.indent <= 3, !marker.content.isEmpty,
           !marker.ordered || marker.number == 1 { return true }
        return false
    }

    /// An open fence in the item so far: its lines are code, never a lazy paragraph continuation.
    static func endsInCode(_ body: [String]) -> Bool {
        var open: Fence.Marker?
        for line in body {
            if let marker = open {
                if Fence.closes(line, marker) { open = nil }
            } else {
                open = Fence.opening(line)
            }
        }
        return open != nil
    }

    static func taskBox(_ line: String) -> (checked: Bool, rest: String)? {
        guard line.count >= 3, line.hasPrefix("["), line.dropFirst(2).first == "]" else { return nil }
        let mark = line.dropFirst().first
        let checked: Bool
        switch mark {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        let rest = line.dropFirst(3)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (checked, String(rest.dropFirst()))
    }

    /// Paragraph lines as one text: a soft break is a space, a line ending in two spaces or `\` a hard break.
    static func join(_ lines: [String]) -> String {
        var text = ""
        for (offset, raw) in lines.enumerated() {
            var line = Substring(raw.drop { $0 == " " })
            let last = offset == lines.count - 1
            var hard = false
            if !last {
                if line.hasSuffix("\\") {
                    line = line.dropLast()
                    hard = true
                } else if line.hasSuffix("  ") {
                    hard = true
                }
            }
            text += line.trimmingCharacters(in: .whitespaces)
            if !last { text += hard ? "\n" : " " }
        }
        return text
    }
}
