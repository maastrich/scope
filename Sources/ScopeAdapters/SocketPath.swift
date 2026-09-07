import Foundation

/// Where the app listens for `scope-hook` messages.
///
/// `sockaddr_un.sun_path` is 104 bytes on macOS (including the terminating NUL), so a socket under a deep
/// `SCOPE_HOME` may not fit. The first choice is `<home>/scope.sock`; when that is too long the socket goes to
/// `$TMPDIR/scope-<uid>.sock` instead. The resolved path is what the app exports as `SCOPE_SOCK`.
public enum SocketPath {
    /// File name of the socket inside `SCOPE_HOME`.
    public static let fileName = "scope.sock"

    /// Longest path (in UTF-8 bytes, without the NUL) a unix socket can be bound to on macOS.
    public static let maxLength = 103

    /// Resolves the socket path for `home`.
    /// - Parameters:
    ///   - home: the `SCOPE_HOME` directory.
    ///   - tmp: the temporary directory used as a fallback (defaults to `$TMPDIR`).
    ///   - uid: the current user id, used to keep fallback sockets of different users apart.
    public static func resolve(home: URL, tmp: String = NSTemporaryDirectory(), uid: uid_t = getuid()) -> String {
        let preferred = home.appendingPathComponent(fileName, isDirectory: false).path
        if fits(preferred) { return preferred }
        return URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("scope-\(uid).sock", isDirectory: false).path
    }

    /// `true` when `path` can be bound as a unix socket on macOS.
    public static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxLength
    }
}
