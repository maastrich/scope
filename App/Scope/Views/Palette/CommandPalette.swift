import SwiftUI
import ScopeCore

/// ⌘K: a floating panel over the main window (design §8). ↑↓ move, ↩ runs, ⌥↩ copies the path of editor and
/// thread rows, Esc closes. Typing filters every section at once.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var items: [PaletteItem] { PaletteModel.filter(PaletteModel.items(model), query: query) }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                inputRow
                Divider()
                results(items)
                Divider()
                footer
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.35), radius: 35, y: 24)
            .padding(.top, 120)
            .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
            .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard let item = items[safe: highlighted] else { return .handled }
                if press.modifiers.contains(.option) {
                    if let path = item.path { Pasteboard.copy(path) }
                } else {
                    close()
                    item.run()
                }
                return .handled
            }
        }
        .onExitCommand { close() }
        .task {
            // The terminal (or the sidebar list) is first responder: take the keyboard once the field exists.
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            TextField("Type a command, a repo or a thread…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
            if let context = contextLabel {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func results(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty {
                        Text("No match")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(Self.rows(items)) { row in
                        switch row {
                        case .header(let section):
                            Text(section.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
                        case .item(let index, let item):
                            PaletteRow(item: item, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture {
                                    close()
                                    item.run()
                                }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
    }

    /// Section headers interleaved with the items, in section order; `index` is the position in `items`.
    private enum Row: Identifiable {
        case header(PaletteItem.Section)
        case item(Int, PaletteItem)

        var id: String {
            switch self {
            case .header(let section): "header-\(section.rawValue)"
            case .item(_, let item): item.id
            }
        }
    }

    private static func rows(_ items: [PaletteItem]) -> [Row] {
        var rows: [Row] = []
        for section in PaletteItem.Section.allCases {
            let members = items.enumerated().filter { $0.element.section == section }
            guard !members.isEmpty else { continue }
            rows.append(.header(section))
            rows.append(contentsOf: members.map { .item($0.offset, $0.element) })
        }
        return rows
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("↑↓ navigate")
            Text("↩ run")
            Text("⌥↩ copy path")
            Spacer()
            Text("esc")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var contextLabel: String? {
        guard let scope = model.currentScope else { return nil }
        if let task = model.currentTask { return "\(scope.name) · \(task.name)" }
        return scope.name
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = ((highlighted + delta) % count + count) % count
    }

    private func close() {
        model.paletteShown = false
        AppDelegate.refocusTerminal()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let state = item.state {
                StateDot(state: state)
                    .frame(width: 15)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
            }
            Text(item.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let hint = item.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(highlighted ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
