import Foundation

extension URL {
    /// Absolute path without percent-encoding and without a trailing slash (a directory URL's
    /// `path(percentEncoded:)` keeps one, git's own listings do not).
    var filesystemPath: String {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
