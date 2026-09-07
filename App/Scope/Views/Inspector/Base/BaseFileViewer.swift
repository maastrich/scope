import AppKit
import SwiftUI

/// Read-only viewer on `MonoTextView`: line-number gutter + monospace text, the target line of a search
/// jump tinted and centred, the search term highlighted wherever it occurs. No syntax colouring in this pass.
struct BaseFileViewer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let base = model.base
        Group {
            switch base.content {
            case nil:
                placeholder("Select a file to read it")
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                placeholder(message)
            case .text(let text):
                // The term is highlighted for files opened from a search jump (the jump sets `targetLine`).
                viewer(text, path: base.selectedPath ?? "", target: base.targetLine, term: base.targetLine == nil ? "" : base.query)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Identity: Hashable {
        let path: String
        let text: String
    }

    private struct Version: Hashable {
        let path: String
        let text: String
        let target: Int?
        let term: String
    }

    private func viewer(_ text: String, path: String, target: Int?, term: String) -> some View {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(spacing: 0) {
            HStack {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(lineCount) lines").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            Divider()
            MonoTextView(
                identity: Identity(path: path, text: text),
                version: Version(path: path, text: text, target: target, term: term),
                build: { BaseDocumentBuilder.build(text: text, highlightedLine: target, term: term) },
                focus: target.map { MonoFocus(anchor: $0 - 1, placement: .center) }
            )
        }
    }
}

/// `text` as numbered lines; `highlightedLine` (1-based) gets a row tint, every case-insensitive occurrence
/// of `term` a find-style background. Anchor `i` is line `i + 1`.
@MainActor
enum BaseDocumentBuilder {
    static func build(text: String, highlightedLine: Int?, term: String) -> MonoDocument {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = max(3, String(rows.count).count)
        let result = NSMutableAttributedString()
        var anchors: [NSRange] = []
        anchors.reserveCapacity(rows.count)
        let gutterAttributes = MonoStyle.base(color: MonoStyle.gutter)
        let bodyAttributes = MonoStyle.base()

        for (index, row) in rows.enumerated() {
            let number = index + 1
            let start = result.length
            var gutter = gutterAttributes
            var body = bodyAttributes
            if number == highlightedLine {
                gutter[.rowBackground] = MonoStyle.lineHighlight
                body[.rowBackground] = MonoStyle.lineHighlight
            }
            result.append(NSAttributedString(string: MonoStyle.gutterText(number, width: width) + "  ", attributes: gutter))
            result.append(NSAttributedString(string: String(row) + "\n", attributes: body))
            anchors.append(NSRange(location: start, length: result.length - start - 1))
        }
        if !term.isEmpty {
            highlight(term, in: result)
        }
        return MonoDocument(text: result, anchors: anchors)
    }

    private static func highlight(_ term: String, in text: NSMutableAttributedString) {
        let string = text.string as NSString
        var search = NSRange(location: 0, length: string.length)
        let color = MonoStyle.termHighlight
        while search.length > 0 {
            let found = string.range(of: term, options: [.caseInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            text.addAttribute(.backgroundColor, value: color, range: found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: string.length - next)
        }
    }
}
