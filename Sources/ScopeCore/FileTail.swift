import Foundation

/// The end of a file that keeps growing — a background command's output — read without loading the rest.
public enum FileTail {
    public enum Result: Sendable, Equatable {
        /// The last `limit` bytes at most, from the first full line in them; `truncated` when the file is longer.
        case text(String, truncated: Bool, size: UInt64)
        /// No file there (any more): Claude Code removes a session's task files with it.
        case missing
        case unreadable
    }

    public static let defaultLimit = 64 * 1024

    public static func read(_ path: String, limit: Int = defaultLimit) -> Result {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .unreadable }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() ?? Data() else { return .unreadable }
        var bytes = data[...]
        // Cut inside a line, and maybe inside a character: start after the first newline.
        if start > 0, let newline = bytes.firstIndex(of: 0x0A) { bytes = bytes[bytes.index(after: newline)...] }
        return .text(String(decoding: bytes, as: UTF8.self), truncated: start > 0, size: size)
    }
}
