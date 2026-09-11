import Foundation

/// Where the app listens for `scope-hook` messages.
///
/// `sockaddr_un.sun_path` is 104 bytes on macOS (including the terminating NUL), so a socket under a deep
/// `SCOPE_HOME` may not fit. The first choice is `<home>/scope.sock`; when that is too long the socket goes to
/// `$TMPDIR/scope-<uid>-<home hash>.sock` instead. The resolved path is what the app exports as `SCOPE_SOCK`.
///
/// The hash keeps two instances with deep homes apart: with one fallback name per user, the second instance to
/// start rebound the path and silently took every hook and control message meant for the first.
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
            .appendingPathComponent("scope-\(uid)-\(homeHash(home)).sock", isDirectory: false).path
    }

    /// 8 hex digits of FNV-1a over the home's path with symlinks resolved, so the app and the CLI agree on the
    /// name whether they were handed `/tmp/…` or `/private/tmp/…`.
    static func homeHash(_ home: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in home.resolvingSymlinksInPath().standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    /// `true` when `path` can be bound as a unix socket on macOS.
    public static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxLength
    }
}
