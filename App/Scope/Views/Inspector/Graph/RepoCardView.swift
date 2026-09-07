import SwiftUI
import ScopeGraph

/// One repository card (design §6): title row, purpose, stack chips, key/value rows, links row.
/// Switches to `RepoCardEditor` while the card is being edited.
struct RepoCardView: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let entry: GraphCardEntry

    private var card: RepoCard { entry.card }
    private var repo: RepoState? {
        scope.repos.first { GraphModel.key(for: $0) == entry.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.graph.editingKey == entry.key {
                RepoCardEditor(entry: entry)
            } else {
                titleRow
                if let purpose = card.purpose, !purpose.isEmpty {
                    Text(purpose)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !card.stack.isEmpty { chips(card.stack) }
                keyValues
                if !card.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(card.tags, id: \.self) { tag in
                            Text("#\(tag)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                actions
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(model.graph.highlightedKey == entry.key ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let remote = card.remote, remote != card.name {
                    Text(remote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if card.edited {
                Text("edited")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color("WarningText"))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Color("WarningText").opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .help("Edited by hand: Analyze keeps this card")
            }
            if let branch = card.defaultBranch {
                Text(branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            if let date = card.lastActivity {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Last commit \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private func chips(_ items: [String]) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                let active = model.graph.filter.caseInsensitiveCompare(item) == .orderedSame
                Button {
                    model.graph.toggleFilter(item)
                } label: {
                    Text(item)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(active ? "Clear the stack filter" : "Filter cards by \(item)")
            }
        }
    }

    @ViewBuilder
    private var keyValues: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !card.entrypoints.isEmpty {
                kv("Entry", mono: card.entrypoints.joined(separator: "  "))
            }
            if let setup = card.setup, !setup.isEmpty { kv("Setup", mono: setup) }
            if let test = card.test, !test.isEmpty { kv("Test", mono: test) }
            if !card.related.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    label("Related")
                    FlowLayout(spacing: 8) {
                        ForEach(card.related, id: \.self) { relation in
                            Button {
                                model.graph.highlightedKey = relation.repo
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: relation.kind == .dependsOn ? "arrow.right" : "arrow.left")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(model.graph.card(relation.repo)?.name ?? relation.repo)
                                }
                                .font(.system(size: 12))
                            }
                            .buttonStyle(.link)
                            .help(relation.kind == .dependsOn ? "depends on \(relation.repo)" : "consumed by \(relation.repo)")
                        }
                    }
                }
            }
        }
    }

    private func kv(_ key: String, mono value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            label(key)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let repo {
                CheckoutPicker(scope: scope, repo: repo)
                Button {
                    model.showBase(repo: repo, in: scope)
                } label: {
                    Label("Base", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.link)
                Button {
                    Reveal.inFinder(repo.url)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.link)
            } else {
                Text("not in the scope any more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                model.graph.editingKey = entry.key
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .controlSize(.small)
        .padding(.top, 2)
    }
}

/// Wraps its children onto as many rows as needed (stack chips, related links).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in layout(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
