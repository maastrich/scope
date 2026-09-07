import Foundation

/// One line of a hunk.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file` marker (applies to the line above it).
        case noNewline
    }

    public let kind: Kind
    /// Line content without the leading marker character and without the trailing newline.
    public let text: String
    /// Line number in the old file (`nil` for additions and markers).
    public let oldLineNumber: Int?
    /// Line number in the new file (`nil` for deletions and markers).
    public let newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// One `@@ -old,count +new,count @@` block.
public struct DiffHunk: Sendable, Equatable, Hashable {
    /// The full `@@ … @@ function` line as printed by git.
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    /// Text after the second `@@` (the enclosing function git guessed), trimmed; empty when none.
    public var context: String {
        guard let range = header.range(of: "@@", options: .backwards) else { return "" }
        return header[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}

/// One file of a diff.
public struct DiffFile: Sendable, Equatable, Hashable, Identifiable {
    public enum Status: String, Sendable, Equatable, Hashable, Codable {
        case added, modified, deleted, renamed
        /// Binary content: git prints no hunks (`Binary files … differ` or a `GIT binary patch`).
        case binary
    }

    /// Path relative to the repository root (renames: the new path). Doubles as the identity within one diff.
    public let path: String
    /// Previous path for renames (and copies).
    public let oldPath: String?
    public let status: Status
    public var additions: Int
    public var deletions: Int
    public var hunks: [DiffHunk]

    public init(path: String, oldPath: String? = nil, status: Status, additions: Int = 0, deletions: Int = 0, hunks: [DiffHunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }

    public var id: String { path }
    public var isBinary: Bool { status == .binary }
    /// `true` when the file shows no hunk (binary, empty file, untracked file too large to inline, or mode-only change).
    public var hasHunks: Bool { !hunks.isEmpty }
}

/// Totals of a diff, for the Delta header (`12 files, +340 −27`).
public struct DiffSummary: Sendable, Equatable, Hashable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public init(_ files: [DiffFile]) {
        self.files = files.count
        self.additions = files.reduce(0) { $0 + $1.additions }
        self.deletions = files.reduce(0) { $0 + $1.deletions }
    }

    public var isEmpty: Bool { files == 0 }
}
