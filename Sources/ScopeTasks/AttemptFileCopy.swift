import Foundation

/// A file of one attempt brought into another, as the Compare view's *Copy into…* does: the working-tree file of the
/// source sandbox overwrites (or creates, or deletes) the same path in the target sandbox. File level, nothing
/// git-aware: the target's own changes were salvaged first by the caller, so an overwrite can be found again.
public enum AttemptFileCopy {
    public enum Outcome: Sendable, Equatable {
        case copied(bytes: Int)
        /// The file is gone from the source attempt, so it goes from the target too.
        case deleted
    }

    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        case unsafePath(String)
        case throughSymlink(String)
        case missingOnBothSides(String)
        case isDirectory(String)

        public var description: String {
            switch self {
            case .unsafePath(let path): "\(path) is not a relative path inside the sandbox"
            case .throughSymlink(let path): "\(path) passes through a symbolic link"
            case .missingOnBothSides(let path): "\(path) exists in neither attempt"
            case .isDirectory(let path): "\(path) is a folder; copy its files one by one"
            }
        }
    }

    /// Relative, inside the sandbox, no `..`, no absolute path, no `.git`.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == ".." || $0.isEmpty }) else { return false }
        return parts.first != ".git"
    }

    /// Copies `path` from `source` to `target`.
    public static func copy(_ path: String, from source: URL, to target: URL) throws -> Outcome {
        guard isSafe(path) else { throw Refusal.unsafePath(path) }
        let from = source.appending(path: path, directoryHint: .notDirectory)
        let to = target.appending(path: path, directoryHint: .notDirectory)
        for (root, file) in [(source, from), (target, to)] where passesThroughSymlink(file, under: root) {
            throw Refusal.throughSymlink(path)
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: from.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw Refusal.isDirectory(path) }
            let data = try Data(contentsOf: from)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
            try data.write(to: to, options: .atomic)
            if let mode = try? manager.attributesOfItem(atPath: from.path)[.posixPermissions] {
                try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: to.path)
            }
            return .copied(bytes: data.count)
        }
        guard manager.fileExists(atPath: to.path) else { throw Refusal.missingOnBothSides(path) }
        try manager.removeItem(at: to)
        return .deleted
    }

    /// `true` when a component of `file` below `root` is a symbolic link (the file itself included): a copy must not
    /// land, or read, outside the sandbox.
    static func passesThroughSymlink(_ file: URL, under root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count else { return false }
        var current = root.standardizedFileURL
        for part in parts[rootParts.count...] {
            current = current.appending(path: part)
            if let kind = try? FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType,
               kind == .typeSymbolicLink {
                return true
            }
        }
        return false
    }
}
