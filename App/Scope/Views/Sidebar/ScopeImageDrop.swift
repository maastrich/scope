import Foundation
import UniformTypeIdentifiers

/// An image dropped on a tile or on a well of the scope settings: a file from Finder, or the picture itself
/// from a browser. A dragged link is not followed — no drop makes the app fetch something from the network.
enum ScopeImageDrop {
    static let types: [UTType] = [.fileURL, .image, .pdf]

    /// Hands the first image the drop carries to `then`; `false` when it carries none.
    static func load(_ providers: [NSItemProvider], then: @escaping @MainActor @Sendable (ScopeLogoSource) -> Void) -> Bool {
        if let file = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = file.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in then(.file(url)) }
            }
            return true
        }
        for type in [UTType.image, .pdf] {
            guard let picture = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { continue }
            _ = picture.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in then(.data(data)) }
            }
            return true
        }
        return false
    }
}
