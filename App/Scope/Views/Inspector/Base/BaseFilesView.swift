import SwiftUI
import ScopeGit

/// Files section: the outline tree of the checkout above the read-only viewer of the selected file.
struct BaseFilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var base = model.base
        VStack(spacing: 0) {
            if let tree = model.base.tree {
                List(selection: $base.selectedPath) {
                    OutlineGroup(tree.children, id: \.path, children: \.optionalChildren) { node in
                        Label {
                            Text(node.name).font(.system(size: 12)).lineLimit(1)
                        } icon: {
                            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                        }
                        .tag(node.path)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, idealHeight: 220, maxHeight: 260)
                .onChange(of: model.base.selectedPath) { _, path in
                    guard let path, model.base.content == nil || !isDirectory(path, in: tree) else { return }
                    if !isDirectory(path, in: tree) { model.base.open(path: path) }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Listing files…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            Divider()
            BaseFileViewer()
        }
    }

    private func isDirectory(_ path: String, in tree: FileNode) -> Bool {
        var node = tree
        for part in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { return false }
            node = next
        }
        return node.isDirectory
    }
}

private extension FileNode {
    /// `nil` for files so `OutlineGroup` shows no disclosure chevron.
    var optionalChildren: [FileNode]? { isDirectory ? children : nil }
}
