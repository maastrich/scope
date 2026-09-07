import SwiftUI

/// Keeps only the directories of a dropped selection (Finder drops files too).
@MainActor
func directoriesOnly(_ urls: [URL]) -> [URL] {
    urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

/// Wraps `content` in a folder drop target built on `.dropDestination(for: URL.self)`.
/// `URL` is `Transferable` as `.fileURL`, so Finder drags arrive as file URLs; files are filtered out and
/// a drop with no folder is refused (the cursor shows the drop is not accepted).
struct FolderDropZone<Content: View>: View {
    @State private var isTargeted = false
    private let onDrop: @MainActor ([URL]) -> Void
    private let content: (_ isTargeted: Bool) -> Content

    /// - Parameters:
    ///   - onDrop: receives the dropped folders (never empty).
    ///   - content: the wrapped view; `isTargeted` is true while a drag hovers the zone.
    init(onDrop: @escaping @MainActor ([URL]) -> Void,
         @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content) {
        self.onDrop = onDrop
        self.content = content
    }

    var body: some View {
        content(isTargeted)
            .folderDropTarget(isTargeted: $isTargeted, onDrop: onDrop)
    }
}

extension View {
    /// Makes the view a folder drop target. Files are filtered out; a drop without any folder is refused.
    func folderDropTarget(isTargeted: Binding<Bool>? = nil,
                          onDrop: @escaping @MainActor ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let folders = directoriesOnly(urls)
            guard !folders.isEmpty else { return false }
            onDrop(folders)
            return true
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
    }
}
