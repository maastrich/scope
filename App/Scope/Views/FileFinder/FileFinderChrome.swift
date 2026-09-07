import SwiftUI

/// The parts of the command palette that change in file-finder mode (⌘P): placeholder, the roots being
/// listed, loading state and the footer hint. The palette itself (`CommandPalette`) hosts both modes so the
/// same engine, keyboard handling and overlay are used.
enum FileFinderChrome {
    static let placeholder = "Go to file… (fuzzy over git ls-files)"

    /// Caption shown in the field's trailing slot: the roots and their file counts, or the loading state.
    @MainActor
    static func caption(_ model: AppModel) -> String? {
        let roots = model.fileRoots
        guard !roots.isEmpty else { return "No repository" }
        let counts = roots.compactMap { model.searchUI.files[$0.url]?.paths.count }
        guard counts.count == roots.count else { return "Listing files…" }
        let total = counts.reduce(0, +)
        if roots.count == 1 { return "\(roots[0].label) · \(total) files" }
        return "\(roots.count) sandboxes · \(total) files"
    }
}

/// Empty state of the file finder before any query or when nothing matches.
struct FileFinderEmptyView: View {
    let query: String
    let hasRoots: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(hasRoots ? (query.isEmpty ? "Type to search files" : "No file matches") : "Select a scope or a task to search its files")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            if hasRoots {
                Text("Base files open in the Base viewer; sandbox files open in the editor.")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
