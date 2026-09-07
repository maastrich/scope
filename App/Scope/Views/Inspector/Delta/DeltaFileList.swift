import SwiftUI
import ScopeGit
import ScopeTasks

/// The file list: a header with the path filter and the A / M / D status chips, then one collapsible group
/// per repo (name, file count, counts) and file rows with the status letter, path (directory in tertiary,
/// name in primary), counts and an editor button.
struct DeltaFileList: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    var filterFocused: FocusState<Bool>.Binding
    @State private var collapsedRepos: Set<String> = []
    @State private var filter = ""
    @State private var statuses: Set<DiffFile.Status> = []

    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty || !statuses.isEmpty }

    private func visibleFiles(_ delta: Delta) -> [DiffFile] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return delta.files.filter { file in
            (needle.isEmpty || file.path.lowercased().contains(needle)) && (statuses.isEmpty || statuses.contains(Self.chipStatus(file.status)))
        }
    }

    /// Renames count as modified, binaries as modified too: the chips are A / M / D.
    private static func chipStatus(_ status: DiffFile.Status) -> DiffFile.Status {
        switch status {
        case .added: .added
        case .deleted: .deleted
        case .modified, .renamed, .binary: .modified
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Divider()
            fileScroll
        }
    }

    private var filterHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Filter files", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused(filterFocused)
                .accessibilityLabel("Filter changed files by path")
                .onKeyPress(.escape) {
                    guard !filter.isEmpty else { return .ignored }
                    filter = ""
                    return .handled
                }
            ForEach([DiffFile.Status.added, .modified, .deleted], id: \.self) { status in
                statusChip(status)
            }
            if isFiltering {
                Button {
                    filter = ""
                    statuses = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filters")
                .accessibilityLabel("Clear filters")
            }
        }
        .padding(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }

    private func statusChip(_ status: DiffFile.Status) -> some View {
        let on = statuses.contains(status)
        let name = switch status {
        case .added: "Added"
        case .deleted: "Deleted"
        default: "Modified"
        }
        return Button {
            if on { statuses.remove(status) } else { statuses.insert(status) }
        } label: {
            Text(Self.letter(status))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? Color.white : statusColor(status))
                .frame(width: 18, height: 16)
                .background(on ? statusColor(status) : statusColor(status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Show only \(name.lowercased()) files")
        .accessibilityLabel("\(name) files")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var fileScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.delta.repos) { repo in
                        if let delta = repo.delta {
                            let files = visibleFiles(delta)
                            if !isFiltering || !files.isEmpty {
                                groupRow(repo, delta: delta, shown: files.count)
                            }
                            if !collapsedRepos.contains(repo.id) {
                                ForEach(files) { file in
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

    private func groupRow(_ repo: RepoDelta, delta: Delta, shown: Int) -> some View {
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
                Text(shown == delta.files.count ? "\(delta.files.count) \(delta.files.count == 1 ? "file" : "files")" : "\(shown) of \(delta.files.count) files")
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
        .accessibilityLabel("\(repo.repo.isScopeRoot ? task.record.scopeName : repo.repo.name), \(shown) files, \(collapsedRepos.contains(repo.id) ? "collapsed" : "expanded")")
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
            .accessibilityLabel("Open \(file.path) in editor")
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
