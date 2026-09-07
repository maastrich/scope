import SwiftUI
import ScopeGit
import ScopeTasks

/// Unified diff of one file: header (path, copy patch, reveal, open in editor), then hunks with a
/// foldable header, old/new gutters, sign column and +/− tinted rows. Scrolls in both directions
/// inside its own container. Plain monospace, no syntax highlighting.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    let repo: TaskRepo
    let ref: DeltaFileRef
    let file: DiffFile

    static let addedBackground = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.14)
    static let removedBackground = Color(red: 1, green: 59 / 255, blue: 48 / 255).opacity(0.12)
    static let hunkText = Color(red: 0.235, green: 0.435, blue: 0.690)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if file.isBinary {
                placeholder("Binary file")
            } else if !file.hasHunks {
                placeholder(file.status == .added ? "Empty or too large to inline" : "No textual change (mode or rename only)")
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                                hunkView(index: index, hunk: hunk)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.delta.focusedHunk) { _, index in
                        if let index { withAnimation { proxy.scrollTo(index, anchor: .top) } }
                    }
                }
            }
        }
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
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.delta.copyPatch() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy patch")
            Button { Reveal.inFinder(fileURL) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            Button {
                model.openInEditorOrCopy(path: repo.sandboxPath, file: fileURL.path, line: file.hunks.first?.newStart)
            } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .help("Open in Editor at the first change (⌥-click copies the path)")
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
            Text(text).font(.system(size: 12)).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func hunkView(index: Int, hunk: DiffHunk) -> some View {
        let collapsed = model.delta.isCollapsed(ref, index)
        Button {
            model.delta.toggleHunk(ref, index)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(hunk.header)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Self.hunkText)
            .padding(.leading, 62)
            .padding(.trailing, 14)
            .frame(height: 20)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(model.delta.focusedHunk == index ? 0.16 : 0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if !collapsed {
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    private func lineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            gutter(line.oldLineNumber).padding(.trailing, 4)
            gutter(line.newLineNumber).padding(.trailing, 6)
            Text(sign(line))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(signColor(line))
                .frame(width: 12, alignment: .center)
            Text(line.kind == .noNewline ? "\\ No newline at end of file" : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 14)
        }
        .frame(height: 18)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(background(line))
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 26, alignment: .trailing)
    }

    private func sign(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .noNewline: " "
        }
    }

    private func signColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: DeltaCounts.added
        case .deletion: DeltaCounts.removed
        case .context, .noNewline: .clear
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: Self.addedBackground
        case .deletion: Self.removedBackground
        case .context, .noNewline: .clear
        }
    }
}
