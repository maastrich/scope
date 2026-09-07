import AppKit
import SwiftUI
import ScopeGit
import ScopeTasks

/// Unified diff of one file: header (path, copy patch, reveal, open in editor), then the hunks rendered
/// as one attributed string in a non-wrapping `NSTextView` (`MonoTextView`): foldable hunk headers,
/// old/new gutters, sign column and full-width +/− tints. Plain monospace, no syntax highlighting.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    let ref: DeltaFileRef
    let file: DiffFile

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
                MonoTextView(
                    identity: DiffIdentity(ref: ref, file: file),
                    version: DiffVersion(ref: ref, file: file, collapsed: collapsed, focused: focused),
                    build: { DiffDocumentBuilder.build(file: file, collapsed: collapsed, focused: focused) },
                    focus: focused.map { MonoFocus(anchor: $0, placement: .top) },
                    onAnchorClick: { index in model.delta.toggleHunk(ref, index) }
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
    }

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

/// Turns a `DiffFile` into the attributed string `MonoTextView` shows. Layout per line:
/// `old(4) new(4) sign text`; hunk headers carry a fold chevron and are clickable (`.anchorIndex`).
@MainActor
enum DiffDocumentBuilder {
    static func build(file: DiffFile, collapsed: Set<Int>, focused: Int?) -> MonoDocument {
        let maxNumber = file.hunks.reduce(0) { partial, hunk in
            max(partial, hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
        }
        let width = max(4, String(maxNumber).count)
        let gutterBlank = String(repeating: " ", count: width * 2 + 1)
        let text = NSMutableAttributedString()
        var anchors: [NSRange] = []

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
            guard !isCollapsed else { continue }
            for line in hunk.lines {
                append(line, to: text, width: width)
            }
        }
        return MonoDocument(text: text, anchors: anchors)
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
