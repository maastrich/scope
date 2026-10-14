import SwiftUI
import ScopeCore
import ScopeGit

/// The Files section: the tree of the base checkout. Closed by default and, once open, every folder closed — the root
/// alone — until you open one; a file opened from Search opens the folders above it and nothing else
/// (`BaseModel.expansion`). A click on a file shows it in the inspector's viewer.
struct FilesSection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var sash: SectionSash?

    /// One visible line of the tree: a node and how deep it sits.
    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    var body: some View {
        CollapsibleSection(section: .files, bodyHeight: bodyHeight, unavailable: "no repository", sash: sash) {
            if let count = model.base.fileCount {
                Text("\(count.formatted()) \(count == 1 ? "file" : "files")")
            } else {
                Text("listing…").foregroundStyle(Ink.tertiary)
            }
        } actions: {
            Button {
                model.base.expansion.collapseAll()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .disabled(model.base.expansion.expanded.isEmpty)
            .help("Collapse All")
            .accessibilityLabel("Collapse all folders")
        } content: {
            tree
        }
    }

    @ViewBuilder
    private var tree: some View {
        if let root = model.base.tree {
            let rows = visibleRows(of: root)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.base.selectedPath) { _, path in
                    if let path { proxy.scrollTo(path) }
                }
            }
            .background(Surface.ground)
        } else {
            HStack {
                ScopeSpinner(size: 12)
                Text("Listing files…").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The nodes on screen: every child of an open folder, depth first, nothing under a closed one.
    private func visibleRows(of root: FileNode) -> [Row] {
        var rows: [Row] = []
        func walk(_ node: FileNode, depth: Int) {
            for child in node.children {
                rows.append(Row(node: child, depth: depth))
                if child.isDirectory, model.base.expansion.isExpanded(child.path) {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    private func rowView(_ row: Row) -> some View {
        let node = row.node
        let selected = model.base.selectedPath == node.path
        let expanded = node.isDirectory && model.base.expansion.isExpanded(node.path)
        return HStack(spacing: 4) {
            Group {
                if node.isDirectory {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            // Monochrome, and thin: an accent-blue folder is the Finder's idiom, and it spends the one colour the
            // chrome has on a row that is not selected.
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Ink.secondary : Ink.tertiary)
                .frame(width: 14)
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(selected ? Fill.selectedTint : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                model.base.expansion.toggle(node.path)
            } else {
                model.base.open(path: node.path)
                model.inspector.show(.file)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(node.isDirectory ? (expanded ? "expanded" : "collapsed") : "")
    }
}
