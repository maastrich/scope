import Foundation

/// Backslash-escaping of a path for a shell command line, the way Terminal.app inserts a dropped file.
///
/// Single quotes would also work, but the user is about to keep typing after the path, and a bare word with
/// escaped spaces reads and edits like what they would have typed themselves.
public enum ShellEscaping {
    /// Bytes that stay bare: letters, digits and the punctuation no POSIX shell interprets. Everything else in
    /// ASCII is escaped; non-ASCII (accented file names) passes through, shells take it literally.
    private static let bare: Set<UInt8> = {
        var set = Set<UInt8>()
        set.formUnion(UInt8(ascii: "a")...UInt8(ascii: "z"))
        set.formUnion(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        set.formUnion(UInt8(ascii: "0")...UInt8(ascii: "9"))
        for byte in "_-./+,:@%=".utf8 { set.insert(byte) }
        return set
    }()

    public static func escaped(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if scalar.isASCII, !bare.contains(UInt8(scalar.value)) {
                out.append("\\")
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// What a drop of `urls` inserts: every path escaped, one space between them and one after, so the user
    /// can go on typing (no newline — nothing runs until they press ↩).
    public static func droppedPaths(_ urls: [URL]) -> String {
        urls.map { escaped($0.path(percentEncoded: false)) }.map { $0 + " " }.joined()
    }
}
