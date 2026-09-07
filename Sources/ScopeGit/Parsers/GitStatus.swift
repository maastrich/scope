import Foundation

/// Parsed output of `git status --porcelain=v2 --branch -z` [verified].
public struct GitStatus: Sendable, Equatable {
    /// What `HEAD` points at.
    public enum Head: Sendable, Equatable {
        /// On a branch that has at least one commit.
        case branch(String)
        /// Detached `HEAD`.
        case detached
        /// Unborn branch: the repository has no commit yet (`git init`).
        case initial
    }

    /// One changed, untracked or ignored path.
    public struct Entry: Sendable, Equatable, Hashable {
        /// The two-letter status: `"M."` staged, `".M"` unstaged, `"A."`, `"??"` untracked, `"!!"` ignored, `"UU"` unmerged…
        public let xy: String
        /// Path relative to the repository root (renames: the new path).
        public let path: String
        /// Previous path for renames and copies.
        public let originalPath: String?

        public init(xy: String, path: String, originalPath: String? = nil) {
            self.xy = xy
            self.path = path
            self.originalPath = originalPath
        }

        public var isUntracked: Bool { xy == "??" }
        public var isIgnored: Bool { xy == "!!" }
        /// Merge conflict (`u` record: `UU`, `AA`, `DU`…).
        public var isUnmerged: Bool { xy.contains("U") || xy == "AA" || xy == "DD" }
        /// Something is in the index for this path.
        public var isStaged: Bool { !isUntracked && !isIgnored && !isUnmerged && xy.first != "." }
        /// The working tree differs from the index for this path.
        public var isUnstaged: Bool { !isUntracked && !isIgnored && !isUnmerged && xy.last != "." }
    }

    public var head: Head = .initial
    /// Commit `HEAD` points at; `nil` on an unborn branch.
    public var oid: String?
    /// Upstream ref (`origin/main`), when the branch tracks one.
    public var upstream: String?
    /// Commits ahead of `upstream` (0 without upstream).
    public var ahead: Int = 0
    /// Commits behind `upstream` (0 without upstream).
    public var behind: Int = 0
    public var entries: [Entry] = []

    public init(
        head: Head = .initial,
        oid: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        entries: [Entry] = []
    ) {
        self.head = head
        self.oid = oid
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
    }

    /// Anything changed, staged, unmerged or untracked. Ignored files do not count.
    public var isDirty: Bool { entries.contains { !$0.isIgnored } }
    public var hasUntracked: Bool { entries.contains(where: \.isUntracked) }
    public var hasConflicts: Bool { entries.contains(where: \.isUnmerged) }
    /// Number of entries that make the tree dirty.
    public var changedCount: Int { entries.filter { !$0.isIgnored }.count }
    /// Branch name when on a born branch; `nil` when detached or on an unborn branch.
    public var branchName: String? {
        if case .branch(let name) = head { return name }
        return nil
    }
    public var isDetached: Bool { head == .detached }

    /// Parses the raw stdout of `git status --porcelain=v2 --branch -z [--untracked-files=normal]`.
    ///
    /// With `-z` every record is NUL-terminated and paths are not C-quoted; rename / copy records
    /// (`2 …`) are followed by one extra NUL-terminated field holding the original path.
    /// Malformed records are skipped, never fatal.
    public init(porcelainV2 output: Data) {
        var records = output
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if records.last == "" { records.removeLast() }   // the trailing NUL leaves an empty field

        var headName: String?
        var detached = false

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1

            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid":
                    oid = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head":
                    if parts[1] == "(detached)" { detached = true } else { headName = parts[1] }
                case "branch.upstream":
                    upstream = parts[1]
                case "branch.ab":
                    for token in parts[1].split(separator: " ") {
                        if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                    }
                default:
                    break
                }
                continue
            }

            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                guard let xy = Self.token(1, in: record), let path = Self.path(afterFixedTokens: 8, in: record) else { continue }
                entries.append(Entry(xy: xy, path: path, originalPath: nil))
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path> NUL <origPath>
                guard let xy = Self.token(1, in: record), let path = Self.path(afterFixedTokens: 9, in: record),
                      index < records.count else { continue }
                let original = records[index]
                index += 1
                entries.append(Entry(xy: xy, path: path, originalPath: original))
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                guard let xy = Self.token(1, in: record), let path = Self.path(afterFixedTokens: 10, in: record) else { continue }
                entries.append(Entry(xy: xy, path: path, originalPath: nil))
            case "?", "!":
                // ? <path>   /   ! <path>
                guard let path = Self.path(afterFixedTokens: 1, in: record) else { continue }
                entries.append(Entry(xy: String(repeating: kind, count: 2), path: path, originalPath: nil))
            default:
                continue
            }
        }

        if detached {
            head = .detached
        } else if let headName, oid != nil {
            head = .branch(headName)
        } else {
            head = .initial
        }
    }

    /// The `position`-th space-separated token of a record (0-based).
    private static func token(_ position: Int, in record: String) -> String? {
        let tokens = record.split(separator: " ", maxSplits: position + 1, omittingEmptySubsequences: false)
        guard tokens.count > position else { return nil }
        return String(tokens[position])
    }

    /// Everything after the first `count` space-terminated tokens: the path, spaces included.
    private static func path(afterFixedTokens count: Int, in record: String) -> String? {
        var remaining = Substring(record)
        for _ in 0..<count {
            guard let space = remaining.firstIndex(of: " ") else { return nil }
            remaining = remaining[remaining.index(after: space)...]
        }
        return remaining.isEmpty ? nil : String(remaining)
    }
}
