import Foundation

/// A fingerprint of one file's diff, for "mark as viewed": a mark is kept while the digest it was taken with still
/// matches, and drops as soon as the agent changes anything in that file's diff.
///
/// FNV-1a over the paths, the status and every hunk line, so it is the same across launches — unlike `Hasher`,
/// which is seeded per process.
public enum DiffDigest {
    public static func of(_ file: DiffFile) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x0a
            hash = hash &* 0x0000_0100_0000_01b3
        }
        mix(file.path)
        mix(file.oldPath ?? "")
        mix(file.status.rawValue)
        for hunk in file.hunks {
            mix(hunk.header)
            for line in hunk.lines {
                let sign = switch line.kind {
                case .context: " "
                case .addition: "+"
                case .deletion: "-"
                case .noNewline: "\\"
                }
                mix(sign + line.text)
            }
        }
        return String(hash, radix: 16)
    }
}
