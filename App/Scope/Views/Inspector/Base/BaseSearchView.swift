import SwiftUI
import ScopeGit

/// Search section: a regex field and the matches (`path:line` + snippet); a click opens the file at
/// that line in the Files section.
struct BaseSearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var base = model.base
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search (regex)", text: $base.query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { Task { await model.base.search() } }
                if model.base.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            Divider()
            if model.base.results.isEmpty {
                Text(model.base.query.isEmpty ? "Type a pattern and press Return" : (model.base.isSearching ? "" : "No match"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.base.results.enumerated()), id: \.offset) { _, match in
                        Button {
                            model.base.section = .files
                            model.base.selectedPath = match.path
                            model.base.open(path: match.path, line: match.line)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(match.path):\(match.line)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(match.text.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text("\(model.base.results.count) \(model.base.results.count == 1 ? "match" : "matches")\(model.base.results.count >= 500 ? " (capped)" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
        }
    }
}
