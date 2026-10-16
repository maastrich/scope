import Foundation

/// How much disk a folder takes, the way `du` counts it: the allocated size of every regular file under it, hard links
/// and symbolic links not followed, the walk never leaving the folder. Off the main actor: a JavaScript sandbox holds
/// a `node_modules` of a hundred thousand files, and that is seconds, not milliseconds.
public enum SandboxSize {
    /// A task's sandboxes, measured: the total, and when.
    public struct Measurement: Sendable, Equatable {
        public var bytes: Int64
        public var measuredAt: Date

        public init(bytes: Int64, measuredAt: Date = .now) {
            self.bytes = bytes
            self.measuredAt = measuredAt
        }
    }

    /// Bytes allocated under `url`, 0 for a folder that is not there. Cancellation stops the walk and returns what
    /// was counted so far.
    public static func bytes(under url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                             options: [.producesRelativePathURLs]) else { return 0 }
        var total: Int64 = 0
        var seenInodes = Set<String>()
        var counted = 0
        for case let file as URL in enumerator {
            counted += 1
            if counted % 2048 == 0, Task.isCancelled { break }
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            // A hard-linked file (pnpm's store) is one file on disk, however many names it has.
            if let identifier = (try? file.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
               !seenInodes.insert("\(identifier)").inserted { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// The sum over several folders, each once.
    public static func bytes(under urls: [URL]) -> Int64 {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }.reduce(0) { $0 + bytes(under: $1) }
    }

    /// `1.2 GB`, `340 MB`, `12 KB`: short, one decimal under 10.
    public static func text(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        let digits = value < 10 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[index])
    }

    /// The `count` largest of `sizes`, biggest first; ties broken by name so the order is stable.
    public static func largest<Key: Comparable>(_ sizes: [Key: Int64], count: Int = 3) -> [(key: Key, bytes: Int64)] {
        Array(sizes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count)).map { (key: $0.key, bytes: $0.value) }
    }
}
