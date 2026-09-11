import AppKit
import SwiftUI
import ScopeGit
import ScopeTasks

/// Unified diff of one file: header (path, copy patch, reveal, open in editor), then the hunks rendered
/// as one attributed string in a non-wrapping `NSTextView` (`MonoTextView`): foldable hunk headers,
/// old/new gutters, sign column and full-width +/− tints. Plain monospace, no syntax highlighting.
///
/// The gutter takes review comments: a "+" shows under the pointer, a click comments one line, a drag down the
/// gutter a range, and the editor opens under the lines. Comments are drawn as tinted rows below the last line
/// they cover — found again by content, since the agent keeps editing — and a click on one edits it.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    let ref: DeltaFileRef
    let file: DiffFile
    @State private var popover = CommentPopover()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if file.isBinary {
                placeholder("Binary file")
            } else if !file.hasHunks {
                placeholder(file.status == .added ? "Empty or too large to inline" : "No textual change (mode or rename only)")
            } else {
                let collapsed = Set(file.hunks.indices.filter { model.delta.isCollapsed(ref, $0) })
                let focused = model.delta.focusedHunk
                let comments = model.review.comments(repo: ref.repo, path: file.path)
                MonoTextView(
                    identity: DiffIdentity(ref: ref, file: file),
                    version: DiffVersion(ref: ref, file: file, collapsed: collapsed, focused: focused, comments: comments),
                    build: { DiffDocumentBuilder.build(file: file, collapsed: collapsed, focused: focused, comments: comments) },
                    focus: focused.map { MonoFocus(anchor: $0, placement: .top) },
                    onAnchorClick: { index in model.delta.toggleHunk(ref, index) },
                    gutterWidth: DiffDocumentBuilder.gutterWidth(for: file),
                    onGutterSelection: { keys, rect, view in startComment(keys, rect: rect, view: view) },
                    onCommentClick: { id, rect, view in editComment(id, rect: rect, view: view) }
                )
            }
        }
    }

    private struct DiffIdentity: Hashable {
        let ref: DeltaFileRef
        let file: DiffFile
    }

    private struct DiffVersion: Hashable {
        let ref: DeltaFileRef
        let file: DiffFile
        let collapsed: Set<Int>
        let focused: Int?
        let comments: [ReviewComment]
    }

    // MARK: Comments

    private func startComment(_ keys: ClosedRange<Int>, rect: NSRect, view: NSView) {
        let lines = ReviewPlacement.commentableLines(of: file)
        guard let (side, anchor) = ReviewPlacement.anchor(for: lines, start: keys.lowerBound, end: keys.upperBound) else { return }
        let review = model.review
        let repo = ref.repo
        let path = file.path
        popover.show(relativeTo: rect, of: view) { close in
            CommentEditor(title: title(side: side, anchor: anchor), initial: "", isNew: true, onSave: { body in
                review.add(ReviewComment(repo: repo, path: path, side: side, anchor: anchor, body: body))
                close()
            }, onDelete: nil, onCancel: close)
        }
    }

    private func editComment(_ id: String, rect: NSRect, view: NSView) {
        guard let comment = model.review.comments.first(where: { $0.id.uuidString == id }) else { return }
        let review = model.review
        popover.show(relativeTo: rect, of: view) { close in
            CommentEditor(title: title(side: comment.side, anchor: comment.anchor), initial: comment.body, isNew: false, onSave: { body in
                review.update(comment.id, body: body)
                close()
            }, onDelete: {
                review.delete(comment.id)
                close()
            }, onCancel: close)
        }
    }

    private func title(side: DiffSide, anchor: ReviewAnchor) -> String {
        let lines = anchor.span == 1 ? "line \(anchor.line)" : "lines \(anchor.line)–\(anchor.lastLine)"
        return "\(file.path), \(lines)\(side == .old ? " (removed)" : "")"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("\(repo.isScopeRoot ? task.record.scopeName : repo.name)/\(file.path)")
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let old = file.oldPath, old != file.path {
                Text("← \(old)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.delta.copyPatch() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy patch")
                .accessibilityLabel("Copy patch")
            Button { Reveal.inFinder(fileURL) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            Button {
                model.openInEditorOrCopy(path: repo.sandboxPath, file: fileURL.path, line: file.hunks.first?.newStart)
            } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .help("Open in Editor at the first change (⌥-click copies the path)")
                .accessibilityLabel("Open in Editor")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var fileURL: URL { repo.sandboxURL.appending(path: file.path, directoryHint: .notDirectory) }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Holds the comment editor's popover for as long as it is on screen.
@MainActor
final class CommentPopover {
    private var popover: NSPopover?

    func show<Content: View>(relativeTo rect: NSRect, of view: NSView, content: (@escaping () -> Void) -> Content) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let close: () -> Void = { [weak popover] in popover?.close() }
        popover.contentViewController = NSHostingController(rootView: content(close))
        // The text view is flipped: the maximum-Y edge is under the lines.
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// The editor of one comment: its lines, the text, Add / Save, Delete for an existing one.
struct CommentEditor: View {
    let title: String
    let isNew: Bool
    let onSave: (String) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, initial: String, isNew: Bool, onSave: @escaping (String) -> Void,
         onDelete: (() -> Void)?, onCancel: @escaping () -> Void) {
        self.title = title
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(width: 340, height: 90)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            HStack(spacing: 8) {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Comment" : "Save") { onSave(trimmed) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

/// Turns a `DiffFile` into the attributed string `MonoTextView` shows. Layout per line:
/// `old(4) new(4) sign text`; hunk headers carry a fold chevron and are clickable (`.anchorIndex`). Every
/// commentable line carries its index in `ReviewPlacement.commentableLines` as `.lineKey`; comments follow the
/// line they hang under as tinted rows (`.commentID`).
@MainActor
enum DiffDocumentBuilder {
    static func build(file: DiffFile, collapsed: Set<Int>, focused: Int?, comments: [ReviewComment] = []) -> MonoDocument {
        let width = numberWidth(for: file)
        let gutterBlank = String(repeating: " ", count: width * 2 + 1)
        let text = NSMutableAttributedString()
        var anchors: [NSRange] = []
        var lines: [Int: NSRange] = [:]
        let placement = ReviewPlacement.place(comments, in: ReviewPlacement.commentableLines(of: file))

        for orphan in placement.orphans {
            appendComment(orphan, to: text, gutterBlank: gutterBlank,
                          note: "line \(orphan.anchor.line) — no longer in this diff")
        }
        var key = 0
        for (index, hunk) in file.hunks.enumerated() {
            let isCollapsed = collapsed.contains(index)
            let chevron = isCollapsed ? "▸" : "▾"
            var attributes = MonoStyle.base(color: MonoStyle.hunkText)
            attributes[.rowBackground] = focused == index ? MonoStyle.focusedHunkBackground : MonoStyle.hunkBackground
            attributes[.anchorIndex] = index
            attributes[.link] = URL(string: "scope-hunk://\(index)") as Any
            attributes[.cursor] = NSCursor.pointingHand
            let header = NSAttributedString(string: "\(gutterBlank) \(chevron) \(hunk.header)\n", attributes: attributes)
            anchors.append(NSRange(location: text.length, length: max(0, header.length - 1)))
            text.append(header)
            let keys = key..<(key + hunk.lines.filter { $0.kind != .noNewline }.count)
            key = keys.upperBound
            if isCollapsed {
                // A folded hunk still shows the comments on its lines, under its header.
                for comment in keys.flatMap({ placement.placed[$0] ?? [] }) {
                    appendComment(comment, to: text, gutterBlank: gutterBlank, note: nil)
                }
                continue
            }
            var lineKey = keys.lowerBound
            for line in hunk.lines {
                guard line.kind != .noNewline else {
                    append(line, to: text, width: width)
                    continue
                }
                let start = text.length
                append(line, to: text, width: width)
                let range = NSRange(location: start, length: text.length - start)
                text.addAttribute(.lineKey, value: lineKey, range: range)
                lines[lineKey] = range
                for comment in placement.placed[lineKey] ?? [] {
                    appendComment(comment, to: text, gutterBlank: gutterBlank, note: nil)
                }
                lineKey += 1
            }
        }
        return MonoDocument(text: text, anchors: anchors, lines: lines)
    }

    /// Width of the line-number gutter in points: both number columns and their separators.
    static func gutterWidth(for file: DiffFile) -> CGFloat {
        let digit = ("0" as NSString).size(withAttributes: [.font: MonoStyle.font]).width
        return CGFloat(numberWidth(for: file) * 2 + 2) * digit
    }

    private static func numberWidth(for file: DiffFile) -> Int {
        let maxNumber = file.hunks.reduce(0) { partial, hunk in
            max(partial, hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
        }
        return max(4, String(maxNumber).count)
    }

    private static var commentBackground: NSColor { NSColor.systemYellow.withAlphaComponent(0.16) }

    private static func appendComment(_ comment: ReviewComment, to text: NSMutableAttributedString, gutterBlank: String,
                                      note: String?) {
        var attributes = MonoStyle.base(color: MonoStyle.text, font: NSFont.systemFont(ofSize: 12))
        attributes[.rowBackground] = commentBackground
        attributes[.commentID] = comment.id.uuidString
        attributes[.link] = URL(string: "scope-comment://\(comment.id.uuidString)") as Any
        attributes[.cursor] = NSCursor.pointingHand
        var rows = comment.body.components(separatedBy: "\n")
        if let note { rows.insert("(\(note))", at: 0) }
        for (index, row) in rows.enumerated() {
            let marker = index == 0 ? " ┃ " : " ┃ "
            text.append(NSAttributedString(string: "\(gutterBlank)\(marker)\(row)\n", attributes: attributes))
        }
    }

    private static func append(_ line: DiffLine, to text: NSMutableAttributedString, width: Int) {
        let gutter = MonoStyle.gutterText(line.oldLineNumber, width: width) + " " + MonoStyle.gutterText(line.newLineNumber, width: width) + " "
        var rowAttributes = MonoStyle.base(color: MonoStyle.gutter)
        let sign: String
        let signColor: NSColor
        let body: String
        var bodyColor = MonoStyle.text
        switch line.kind {
        case .addition:
            rowAttributes[.rowBackground] = MonoStyle.diffAdded
            sign = "+"
            signColor = MonoStyle.diffAddedSign
            body = line.text
        case .deletion:
            rowAttributes[.rowBackground] = MonoStyle.diffRemoved
            sign = "−"
            signColor = MonoStyle.diffRemovedSign
            body = line.text
        case .context:
            sign = " "
            signColor = .clear
            body = line.text
        case .noNewline:
            sign = " "
            signColor = .clear
            body = "\\ No newline at end of file"
            bodyColor = MonoStyle.muted
        }
        text.append(NSAttributedString(string: gutter, attributes: rowAttributes))
        var signAttributes = rowAttributes
        signAttributes[.foregroundColor] = signColor
        signAttributes[.font] = MonoStyle.signFont
        text.append(NSAttributedString(string: sign + " ", attributes: signAttributes))
        var bodyAttributes = rowAttributes
        bodyAttributes[.foregroundColor] = bodyColor
        text.append(NSAttributedString(string: body + "\n", attributes: bodyAttributes))
    }
}
