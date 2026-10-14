import AppKit
import ScopeCore

/// Which of a scope's two images: the one shown everywhere, or the one that replaces it in the dark appearance.
enum ScopeLogoSlot: Hashable {
    case standard, dark

    var keyPath: WritableKeyPath<ScopeDeclaration, String?> {
        switch self {
        case .standard: \.logo
        case .dark: \.logoDark
        }
    }
}

/// Where a scope image comes from: a file (the picker, a drop from Finder), bytes (a drop from a browser), or a
/// decoded image (the clipboard).
enum ScopeLogoSource: Sendable {
    case file(URL)
    case data(Data)

    /// What the pasteboard holds that can be a scope image: a copied file first, else copied pixels.
    @MainActor
    static func pasteboard(_ pasteboard: NSPasteboard = .general) -> ScopeLogoSource? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let url = urls?.first { return .file(url) }
        for type in [NSPasteboard.PasteboardType.png, .tiff, .pdf] {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        return nil
    }
}

/// The scope images under `<home>/scope-logos/`: imports them in their stored form (`ScopeLogo`), reads them back
/// for the tiles, and deletes the ones nothing points at any more.
@MainActor
final class ScopeLogoStore {
    struct Logo {
        let image: NSImage
        let style: ScopeLogo.Style
    }

    private let folder: URL
    /// By file name; a miss is kept too, so a file deleted behind the app is not looked for at every redraw.
    private var cache: [String: Logo?] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    private func url(_ name: String) -> URL {
        folder.appending(path: name, directoryHint: .notDirectory)
    }

    func logo(named name: String) -> Logo? {
        if let known = cache[name] { return known }
        var logo: Logo?
        if let data = try? Data(contentsOf: url(name)), let image = ScopeLogo.decode(data) {
            logo = Logo(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                        style: ScopeLogo.style(of: image))
        }
        cache[name] = .some(logo)
        return logo
    }

    /// Imports `source` and returns the name of the new file. A fresh name per import: the cache and SwiftUI both
    /// key on it, so a replaced image shows at once.
    ///
    /// `enforcingShape: false` is for the copies an older build made: see `ScopeLogo.normalized`.
    func save(_ source: ScopeLogoSource, slug: String, enforcingShape: Bool = true) throws -> String {
        let png = try Self.normalized(source, enforcingShape: enforcingShape)
        let name = "\(slug)-\(UUID().uuidString.prefix(8).lowercased()).png"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: url(name), options: .atomic)
        return name
    }

    func remove(named name: String) {
        cache[name] = nil
        try? FileManager.default.removeItem(at: url(name))
    }

    /// The bytes of a stored file, for the migration of the copies v0.14.0 made.
    func data(named name: String) -> Data? {
        try? Data(contentsOf: url(name))
    }

    /// Deletes every file no declaration names: what a crash between a copy and a save, or a scope removed by
    /// an older build, left behind.
    func sweep(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where !names.contains(file) && !file.hasPrefix(".") {
            remove(named: file)
        }
    }

    private static func normalized(_ source: ScopeLogoSource, enforcingShape: Bool) throws -> Data {
        let data: Data
        switch source {
        case .file(let url):
            // Asked of the file system first: a multi-gigabyte file is refused without being read.
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ScopeLogo.maximumSourceBytes {
                throw ScopeLogo.Failure.tooHeavy(bytes: size)
            }
            data = try Data(contentsOf: url)
        case .data(let bytes):
            data = bytes
        }
        if let vector = rasterizedVector(data) { return try ScopeLogo.normalized(vector, enforcingShape: enforcingShape) }
        return try ScopeLogo.normalized(data, enforcingShape: enforcingShape)
    }

    /// An SVG or a PDF drawn large enough to be reduced cleanly. ImageIO, which the package reads with, knows
    /// neither as a picture; AppKit does.
    private static func rasterizedVector(_ data: Data) -> CGImage? {
        guard data.count <= ScopeLogo.maximumSourceBytes, let image = NSImage(data: data),
              !image.representations.isEmpty, !image.representations.contains(where: { $0 is NSBitmapImageRep }),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale = 512 / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}
