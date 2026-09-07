import SwiftUI
import ScopeGit
import ScopeTasks

/// The file list: one collapsible group per repo (name, file count, counts), then file rows with the
/// status letter, path (directory in tertiary, name in primary), counts and an editor button.
struct DeltaFileList: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.delta.repos) { repo in
                        if let delta = repo.delta {
                            groupRow(repo, delta: delta)
                            if !collapsedRepos.contains(repo.id) {
                                ForEach(delta.files) { file in
                                    let ref = DeltaFileRef(repo: repo.id, path: file.path)
                                    fileRow(repo: repo.repo, ref: ref, file: file)
                                        .id(ref)
                                }
                            }
                        } else if let error = repo.error {
                            HStack(spacing: 6) {
                                Text(repo.repo.name).font(.system(size: 12, weight: .semibold))
                                Text(error).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                        }
                    }
                }
            }
            .onChange(of: model.delta.selectedFile) { _, ref in
                if let ref { proxy.scrollTo(ref) }
            }
        }
    }

    private func groupRow(_ repo: RepoDelta, delta: Delta) -> some View {
        Button {
            if collapsedRepos.contains(repo.id) { collapsedRepos.remove(repo.id) } else { collapsedRepos.insert(repo.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedRepos.contains(repo.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 11)
                Text(repo.repo.isScopeRoot ? task.record.scopeName : repo.repo.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(delta.files.count) \(delta.files.count == 1 ? "file" : "files")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                DeltaCounts(additions: delta.summary.additions, deletions: delta.summary.deletions)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.03))
    }

    private func fileRow(repo: TaskRepo, ref: DeltaFileRef, file: DiffFile) -> some View {
        let selected = model.delta.selectedFile == ref
        return HStack(spacing: 8) {
            Text(statusLetter(file.status))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 14)
            pathText(file.path)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            DeltaCounts(additions: file.additions, deletions: file.deletions)
            Button {
                model.openInEditorOrCopy(path: repo.sandboxPath, file: repo.sandboxURL.appending(path: file.path).path,
                                         line: file.hunks.first?.newStart)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Open in Editor (⌥-click copies the path)")
        }
        .padding(EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 14))
        .frame(height: 26)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.delta.selectedFile = ref
            model.delta.focusedHunk = nil
        }
    }

    private func pathText(_ path: String) -> Text {
        guard let slash = path.lastIndex(of: "/") else { return Text(path) }
        let directory = String(path[...slash])
        let name = String(path[path.index(after: slash)...])
        return Text(directory).foregroundStyle(.tertiary) + Text(name)
    }

    static func letter(_ status: DiffFile.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .binary: "B"
        }
    }

    private func statusLetter(_ status: DiffFile.Status) -> String { Self.letter(status) }

    private func statusColor(_ status: DiffFile.Status) -> Color {
        switch status {
        case .added: DeltaCounts.added
        case .deleted: DeltaCounts.removed
        case .modified, .renamed: Color(nsColor: .systemOrange)
        case .binary: Color(nsColor: .systemGray)
        }
    }
}
