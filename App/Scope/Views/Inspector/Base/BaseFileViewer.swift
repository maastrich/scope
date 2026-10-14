import AppKit
import SwiftUI

/// Read-only viewer on `MonoTextView`: line-number gutter + monospace text, the target line of a search
/// jump tinted and centred, the search term highlighted wherever it occurs. No syntax colouring in this pass.
struct BaseFileViewer: View {
    @Environment(AppModel.self) private var model
    /// Controls the host puts at the ends of the header (the viewer column: back, close).
    var leading: AnyView?
    var trailing: AnyView?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    /// One header whatever the state, so the viewer's own controls are there while a file loads or fails too.
    private var header: some View {
        let base = model.base
        let caption: String = switch base.content {
        case .text(let text): "\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
        case .image(let data): DecodedImage(data: data)?.caption ?? "undecodable image"
        default: ""
        }
        return HStack(spacing: 8) {
            if let leading { leading }
            Image(systemName: "doc.text")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            if let path = base.selectedPath {
                FilePathLabel(path: path)
            }
            Spacer(minLength: 4)
            Text(caption)
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .fixedSize()
            if let trailing {
                HStack(spacing: 2) { trailing }.fixedSize()
            }
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Surface.panel)
    }

    @ViewBuilder
    private var content: some View {
        let base = model.base
        Group {
            switch base.content {
            case nil:
                placeholder("Select a file to read it")
            case .loading:
                ScopeSpinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                placeholder(message)
            case .image(let data):
                imageViewer(data, path: base.selectedPath ?? "")
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
            .foregroundStyle(Ink.secondary)
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

    private func imageViewer(_ data: Data, path: String) -> some View {
        let image = DecodedImage(data: data)
        return VStack(spacing: 0) {
            if let image {
                ImageCanvas(image: image)
            } else {
                placeholder("This image could not be decoded.")
            }
        }
    }

    private func viewer(_ text: String, path: String, target: Int?, term: String) -> some View {
        return VStack(spacing: 0) {
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
