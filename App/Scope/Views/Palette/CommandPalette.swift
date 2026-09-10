import SwiftUI
import ScopeCore

/// ⌘K: a floating panel over the main window (design §8). ↑↓ move, ↩ runs, ⌥↩ copies the path of editor,
/// thread and file rows, Esc closes. Typing filters every section at once. In `.files` mode (⌘P) the
/// same panel shows the Files section alone.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var mode: PaletteMode { model.searchUI.paletteMode }
    private var items: [PaletteItem] { PaletteModel.results(model, query: query, mode: mode) }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Color("PaletteDim")
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                inputRow
                Divider()
                results(items)
                Divider()
                footer
            }
            .frame(width: 620)
            .fixedSize(horizontal: false, vertical: true)
            // Opaque, not a material: a material blurs what lies under it, and under the panel lies the dimming
            // scrim — the panel came out grey (`#d6d9da` measured in light mode), a shade above the backdrop it is
            // supposed to stand in front of.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.35), radius: 35, y: 24)
            .padding(.top, 120)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
            .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard let item = items[safe: highlighted] else { return .handled }
                if press.modifiers.contains(.option) {
                    if let path = item.path { Pasteboard.copy(path) }
                } else {
                    choose(item)
                }
                return .handled
            }
            .accessibilityLabel(mode == .files ? "Go to File" : "Command Palette")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: mode)
        .onExitCommand { close() }
        .task {
            model.refreshFileLists()
            // The terminal (or the sidebar list) is first responder: take the keyboard once the field exists.
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .onChange(of: query) { highlighted = 0 }
        .onChange(of: mode) { query = ""; highlighted = 0 }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .files ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField(mode == .files ? FileFinderChrome.placeholder : "Type a command, a file, a repo or a thread…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .accessibilityLabel(mode == .files ? "File name" : "Command or search")
            if let context = contextLabel {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .frame(maxWidth: 220)
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
                        if mode == .files {
                            FileFinderEmptyView(query: query, hasRoots: !model.fileRoots.isEmpty)
                        } else {
                            Text("No match")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    ForEach(Self.rows(items)) { row in
                        switch row {
                        case .header(let section):
                            Text(section.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
                                .accessibilityAddTraits(.isHeader)
                        case .item(let index, let item):
                            PaletteRow(item: item, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { choose(item) }
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
            Text(mode == .files ? "↩ open" : "↩ run")
            Text("⌥↩ copy path")
            if mode == .files {
                Text("⌘K everything")
            } else {
                Text("⌘P files")
            }
            Spacer()
            Text("esc")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var contextLabel: String? {
        if mode == .files { return FileFinderChrome.caption(model) }
        guard let scope = model.currentScope else { return nil }
        if let task = model.currentTask { return "\(scope.name) · \(task.name)" }
        return scope.name
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = ((highlighted + delta) % count + count) % count
    }

    private func choose(_ item: PaletteItem) {
        model.searchUI.noteChosen(item.id)
        close()
        item.run()
    }

    private func close() {
        model.paletteShown = false
        model.searchUI.paletteMode = .all
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
                    .accessibilityHidden(true)
            }
            Text(Self.emphasized(item.label, at: item.hintMatched ? [] : item.matched, monospaced: item.section == .files))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.hint.map { "\(item.label), \($0)" } ?? item.label)
        .accessibilityAddTraits(.isButton)
    }

    /// `text` with the matched character positions in bold (and the accent colour).
    static func emphasized(_ text: String, at positions: [Int], monospaced: Bool) -> AttributedString {
        var result = AttributedString(text)
        if monospaced { result.font = .system(size: 12.5, design: .monospaced) }
        guard !positions.isEmpty else { return result }
        let matched = Set(positions)
        var index = result.startIndex
        var offset = 0
        while index < result.endIndex {
            let next = result.index(afterCharacter: index)
            if matched.contains(offset) {
                result[index..<next].font = monospaced ? .system(size: 12.5, weight: .bold, design: .monospaced) : .system(size: 13, weight: .bold)
                result[index..<next].foregroundColor = .accentColor
            }
            index = next
            offset += 1
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
