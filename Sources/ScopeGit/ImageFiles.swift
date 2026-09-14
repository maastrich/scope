import Foundation

/// Image files the inspector previews instead of refusing as binary.
///
/// Detection goes by extension, not by sniffing: git already told us the file is binary, and the viewer
/// only needs to know whether AppKit can decode it. SVG is deliberately absent — it is text, and its
/// textual diff is the useful one.
public enum ImageFiles {
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico", "icns",
    ]

    /// 20 MiB: larger images are refused with `BaseError.fileTooLarge`.
    public static let maxBytes = 20 * 1_048_576

    public static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Bytes of the image at `url`; `nil` when there is no such file (a deleted file, or an added file
    /// looked up on the old side). Throws `BaseError.fileTooLarge` past `maxBytes`.
    public static func read(at url: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw BaseError.fileTooLarge(path: url.path, bytes: size) }
        return try Data(contentsOf: url)
    }

    /// Bytes of `path` as committed at `ref` in `checkout`; `nil` when `ref` has no such path (the file is
    /// new). `ref` is anything `git show` accepts (`HEAD`, a merge-base sha). Throws `BaseError.fileTooLarge`
    /// past `maxBytes`.
    public static func blob(_ path: String, at ref: String, in checkout: URL, using client: GitClient) async throws -> Data? {
        let arguments = ["-C", checkout.filesystemPath, "show", "\(ref):\(path)"]
        let result = try await client.run(arguments, timeout: Delta.commandTimeout, allowFailure: true)
        guard result.succeeded else { return nil }
        guard result.stdout.count <= maxBytes else { throw BaseError.fileTooLarge(path: path, bytes: result.stdout.count) }
        return result.stdout
    }
}
