import SwiftUI
import ScopeGit

/// Search section: the field (with the `Aa` / `.*` / `\b` toggles, the tool chip and the match count), an
/// optional subpath scope, and the matches grouped by file. Typing searches after 250 ms from three
/// characters, Return searches at once; ↑↓ move through the matches and Return opens the highlighted one
/// in the Files section.
struct BaseSearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var debounce: Task<Void, Never>?
    @State private var collapsed: Set<String> = []
    @State private var highlighted = 0
    @State private var showSubpath = false

    private static let debounceDelay: Duration = .milliseconds(250)
    private static let debounceMinimum = 3

    /// The matches of one file, in file order.
    private struct FileGroup: Identifiable {
        let path: String
        let matches: [SearchMatch]
        var id: String { path }
    }

    private var groups: [FileGroup] {
        var order: [String] = []
        var byPath: [String: [SearchMatch]] = [:]
        for match in model.base.results {
            if byPath[match.path] == nil { order.append(match.path) }
            byPath[match.path, default: []].append(match)
        }
        return order.map { FileGroup(path: $0, matches: byPath[$0] ?? []) }
    }

    /// The matches the keyboard walks: every match of the expanded files.
    private var visibleMatches: [SearchMatch] {
        groups.filter { !collapsed.contains($0.path) }.flatMap(\.matches)
    }

    var body: some View {
        @Bindable var base = model.base
        let groups = groups
        let visible = visibleMatches
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                searchField(base: $base, visibleCount: visible.count)
                if showSubpath || !base.searchSubpath.isEmpty {
                    subpathField(base: $base)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            Divider()
            if let error = model.base.searchError {
                inlineError(error)
            } else if groups.isEmpty {
                emptyState
            } else {
                resultsList(groups, visible: visible)
            }
        }
        .task {
            // Entering the section: take the keyboard from the terminal once the field exists.
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
        .onChange(of: model.base.query) { _, query in
            debounce?.cancel()
            highlighted = 0
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                model.base.clearSearch()
            } else if trimmed.count >= Self.debounceMinimum {
                debounce = Task {
                    try? await Task.sleep(for: Self.debounceDelay)
                    guard !Task.isCancelled else { return }
                    await model.base.search()
                }
            }
        }
        .onChange(of: model.base.searchOptions) { runNow() }
        .onChange(of: model.base.searchSubpath) { runNow() }
        .onChange(of: model.base.results.count) { highlighted = 0; collapsed = [] }
    }

    // MARK: Field

    private func searchField(base: Bindable<BaseModel>, visibleCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField(model.base.searchOptions.regex ? "Search (regex)" : "Search", text: base.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .accessibilityLabel("Search the base checkout")
                .onSubmit { submit(visibleCount: visibleCount) }
                .onKeyPress(.upArrow) { moveHighlight(-1, count: visibleCount) }
                .onKeyPress(.downArrow) { moveHighlight(1, count: visibleCount) }
                .onKeyPress(.escape) {
                    guard !model.base.query.isEmpty else { return .ignored }
                    model.base.query = ""
                    return .handled
                }
            if model.base.isSearching {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Searching")
            } else if !model.base.results.isEmpty {
                Text(countLabel)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("\(model.base.results.count) matches")
            }
            toggle("Aa", help: "Match case", isOn: base.searchOptions.caseSensitive)
            toggle(".*", help: "Regular expression", isOn: base.searchOptions.regex)
            toggle("\\b", help: "Whole word", isOn: base.searchOptions.wholeWord)
            Button {
                showSubpath.toggle()
                if !showSubpath { model.base.searchSubpath = "" }
            } label: {
                Image(systemName: showSubpath || !model.base.searchSubpath.isEmpty ? "folder.fill" : "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(showSubpath || !model.base.searchSubpath.isEmpty ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Limit the search to a subpath")
            .accessibilityLabel("Limit to subpath")
            toolChip
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
    }

    private func subpathField(base: Bindable<BaseModel>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Subpath, e.g. src/lib (optional)", text: base.searchSubpath)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .accessibilityLabel("Subpath scope")
                .onSubmit { runNow() }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func toggle(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                .frame(width: 22, height: 16)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    private var toolChip: some View {
        Text(model.base.searchTool.displayName)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            .help(toolHelp)
            .accessibilityLabel("Search tool: \(model.base.searchTool.displayName)")
    }

    private var toolHelp: String {
        switch model.base.searchTool {
        case .ripgrep(let path): "ripgrep (\(path)): Rust regex syntax, .gitignore respected. Toggles map to -s/-i, -F and -w."
        case .gitGrep: "git grep: POSIX extended regex (-E), tracked and untracked files. Install rg for faster searches."
        }
    }

    private var countLabel: String {
        let count = model.base.results.count
        let files = groups.count
        let capped = count >= 500 ? "+" : ""
        return "\(count)\(capped) in \(files) \(files == 1 ? "file" : "files")"
    }

    // MARK: Results

    private var emptyState: some View {
        let query = model.base.query.trimmingCharacters(in: .whitespaces)
        let text: String = if query.isEmpty {
            "Type to search · Return searches at once"
        } else if model.base.isSearching {
            ""
        } else if model.base.searchedQuery == nil, query.count < Self.debounceMinimum {
            "Press Return to search"
        } else {
            "No match"
        }
        return Group {
            if model.base.isSearching, model.base.results.isEmpty {
                DeltaSkeleton()
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Search failed", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
            Button("Retry") { runNow() }
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resultsList(_ groups: [FileGroup], visible: [SearchMatch]) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    fileHeader(group)
                    if !collapsed.contains(group.path) {
                        ForEach(Array(group.matches.enumerated()), id: \.offset) { _, match in
                            let index = visible.firstIndex(of: match) ?? -1
                            matchRow(match, highlighted: index == highlighted)
                                .id(index)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 20)
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
    }

    private func fileHeader(_ group: FileGroup) -> some View {
        Button {
            if collapsed.contains(group.path) { collapsed.remove(group.path) } else { collapsed.insert(group.path) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(group.path) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
                pathText(group.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("+\(group.matches.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityLabel("\(group.path), \(group.matches.count) matches, \(collapsed.contains(group.path) ? "collapsed" : "expanded")")
    }

    private func matchRow(_ match: SearchMatch, highlighted: Bool) -> some View {
        Button {
            open(match)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(match.line)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(Self.snippet(match))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Line \(match.line): \(match.text.trimmingCharacters(in: .whitespaces))")
    }

    /// The line with its match ranges in bold. Leading whitespace is dropped and the ranges shifted.
    static func snippet(_ match: SearchMatch) -> AttributedString {
        let leading = match.text.prefix { $0 == " " || $0 == "\t" }.count
        let text = String(match.text.dropFirst(leading))
        var result = AttributedString(text)
        for range in match.submatches {
            let lower = max(0, range.lowerBound - leading), upper = min(text.count, range.upperBound - leading)
            guard lower < upper else { continue }
            let start = result.index(result.startIndex, offsetByCharacters: lower)
            let end = result.index(result.startIndex, offsetByCharacters: upper)
            result[start..<end].font = .system(size: 11.5, weight: .bold, design: .monospaced)
            result[start..<end].foregroundColor = .accentColor
        }
        return result
    }

    private func pathText(_ path: String) -> Text {
        guard let slash = path.lastIndex(of: "/") else { return Text(path) }
        return Text(String(path[...slash])).foregroundStyle(.tertiary) + Text(String(path[path.index(after: slash)...]))
    }

    // MARK: Actions

    private func submit(visibleCount: Int) {
        let query = model.base.query.trimmingCharacters(in: .whitespaces)
        if model.base.searchedQuery == query, !query.isEmpty, let match = visibleMatches[safe: highlighted] {
            open(match)
        } else {
            runNow()
        }
    }

    private func runNow() {
        debounce?.cancel()
        Task { await model.base.search() }
    }

    private func moveHighlight(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = ((highlighted + delta) % count + count) % count
        return .handled
    }

    private func open(_ match: SearchMatch) {
        model.base.section = .files
        model.base.selectedPath = match.path
        model.base.open(path: match.path, line: match.line)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
