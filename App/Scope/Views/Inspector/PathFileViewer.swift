import SwiftUI
import ScopeCore

/// A file a thread printed and the user clicked, read-only, the line the link named brought into view and tinted.
/// The header says which copy it is — the task's, the base's, or a file outside the scope — offers the other files
/// the link could mean when there are several, and switches to the diff when the task changed this file.
struct PathFileViewer: View {
    @Environment(AppModel.self) private var model
    var leading: AnyView?
    var trailing: AnyView?

    var body: some View {
        if let preview = model.inspector.pathPreview {
            VStack(spacing: 0) {
                header(preview)
                Divider()
                content(preview)
            }
        }
    }

    private func header(_ preview: PathPreview) -> some View {
        let candidate = preview.current
        return HStack(spacing: 8) {
            if let leading { leading }
            originChip(candidate.origin, names: preview.repoNames)
            FilePathLabel(path: candidate.relativePath ?? candidate.path)
                .help(candidate.path)
            Spacer(minLength: 4)
            if preview.candidates.count > 1 {
                ScopeIconMenu(systemImage: "square.stack", title: "\(preview.candidates.count) files match this link") {
                    ForEach(preview.candidates.indices, id: \.self) { index in
                        Button(label(preview.candidates[index], names: preview.repoNames)) {
                            model.choosePathCandidate(index)
                        }
                    }
                }
            }
            if let ref = diffRef(candidate) {
                Button {
                    model.showDiff(ref)
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                }
                .help("The task changed this file — show its diff")
                .accessibilityLabel("Show the diff")
            }
            Button {
                // The repository as the folder, so the editor opens the project around the file.
                let folder = candidate.relativePath.map { String(candidate.path.dropLast($0.count + 1)) }
                    ?? (candidate.path as NSString).deletingLastPathComponent
                model.openInEditorOrCopy(path: folder, file: candidate.path, line: preview.line)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("Open in Editor (⌥-click copies the path)")
            .accessibilityLabel("Open in Editor")
            if let trailing { trailing }
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Surface.panel)
    }

    @ViewBuilder
    private func content(_ preview: PathPreview) -> some View {
        switch preview.content {
        case nil, .loading:
            ScopeSpinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data):
            if let image = DecodedImage(data: data) {
                ImageCanvas(image: image)
            } else {
                Text("This image could not be decoded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .text(let text):
            let path = preview.current.path
            MonoTextView(
                identity: Identity(path: path, text: text),
                version: Version(path: path, text: text, line: preview.line),
                build: { BaseDocumentBuilder.build(text: text, highlightedLine: preview.line, term: "") },
                focus: preview.line.map { MonoFocus(anchor: $0 - 1, placement: .center) }
            )
        }
    }

    private struct Identity: Hashable {
        let path: String
        let text: String
    }

    private struct Version: Hashable {
        let path: String
        let text: String
        let line: Int?
    }

    /// `hashup · task`, `hashup · base`, `file`: which copy of the file this is, at a glance.
    private func originChip(_ origin: FileLinkResolver.Origin, names: [String: String]) -> some View {
        let (text, help): (String, String) = switch origin {
        case .task(let repo): ("\(names[repo] ?? repo) · task", "The task's sandbox: the version the agent is working on")
        case .base(let repo): ("\(names[repo] ?? repo) · base", "The base checkout, outside any sandbox")
        case .external: ("file", "A file outside the scope's repositories")
        }
        return Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .fixedSize()
            .help(help)
    }

    private func label(_ candidate: FileLinkResolver.Candidate, names: [String: String]) -> String {
        switch candidate.origin {
        case .task(let repo): "\(names[repo] ?? repo) (task) — \(candidate.relativePath ?? candidate.path)"
        case .base(let repo): "\(names[repo] ?? repo) (base) — \(candidate.relativePath ?? candidate.path)"
        case .external: candidate.path
        }
    }

    /// The Delta entry of this file when it is the task's copy and the task changed it.
    private func diffRef(_ candidate: FileLinkResolver.Candidate) -> DeltaFileRef? {
        guard case .task(let repo) = candidate.origin, let relative = candidate.relativePath,
              let task = model.currentTask, model.delta.taskID == task.id else { return nil }
        let ref = DeltaFileRef(repo: repo, path: relative)
        return model.delta.file(ref) != nil ? ref : nil
    }
}
