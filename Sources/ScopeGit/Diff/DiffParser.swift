import Foundation

/// Parser of `git diff` unified output (run with `--no-color -M --no-ext-diff -c core.quotePath=false`)
/// and of `git diff --numstat -z`.
///
/// Tolerant: unknown header lines are skipped, a truncated last hunk keeps what it has, an empty
/// input yields no file. Additions / deletions are counted from the hunks; `parseNumstat` gives
/// the same numbers cheaper and also covers what the patch does not (binary sizes are `-`).
public enum DiffParser {
    /// Parses a unified diff into files. `git diff` with no changes prints nothing → `[]`.
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: FileBuilder?

        func flush() {
            if let built = current?.build() { files.append(built) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.hasPrefix("diff --git ") {
                flush()
                current = FileBuilder(gitHeader: String(line.dropFirst("diff --git ".count)))
                continue
            }
            guard current != nil else { continue }   // preamble (stat, etc.) is ignored

            if current!.inHunk, let first = line.first, first == " " || first == "+" || first == "-" || first == "\\" {
                // `--- ` / `+++ ` only appear before the first hunk; inside a hunk they are content.
                current!.appendHunkLine(String(line))
                continue
            }
            if line.hasPrefix("@@") {
                current!.startHunk(String(line))
            } else if line.hasPrefix("--- ") {
                current!.oldHeader = stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                current!.newHeader = stripPathPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("rename from ") {
                current!.renameFrom = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                current!.renameTo = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                current!.renameFrom = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                current!.renameTo = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("new file mode") {
                current!.isNew = true
            } else if line.hasPrefix("deleted file mode") {
                current!.isDeleted = true
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current!.isBinary = true
            } else if line.isEmpty {
                current!.inHunk = false   // trailing newline of the output, or a blank separator
            }
        }
        flush()
        return files
    }

    /// Parses `git diff --numstat -z` output: `<add>\t<del>\t<path>NUL`, or for renames
    /// `<add>\t<del>\tNUL<old>NUL<new>NUL`. Binary files carry `-` and map to `nil` counts.
    /// Keyed by the (new) path.
    public static func parseNumstat(_ data: Data) -> [String: NumstatEntry] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        var result: [String: NumstatEntry] = [:]
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = Int(parts[0])
            let deletions = Int(parts[1])
            var oldPath: String? = nil
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: the next two fields are the old and the new path.
                guard index + 1 < fields.count else { break }
                oldPath = fields[index]
                path = fields[index + 1]
                index += 2
            }
            result[path] = NumstatEntry(additions: additions, deletions: deletions, oldPath: oldPath)
        }
        return result
    }

    /// Applies numstat counts over parsed files (numstat is authoritative when present).
    public static func merge(_ files: [DiffFile], numstat: [String: NumstatEntry]) -> [DiffFile] {
        files.map { file in
            guard let entry = numstat[file.path] else { return file }
            var copy = file
            copy.additions = entry.additions ?? file.additions
            copy.deletions = entry.deletions ?? file.deletions
            return copy
        }
    }

    public struct NumstatEntry: Sendable, Equatable {
        /// `nil` for binary files.
        public let additions: Int?
        public let deletions: Int?
        public let oldPath: String?

        public init(additions: Int?, deletions: Int?, oldPath: String? = nil) {
            self.additions = additions
            self.deletions = deletions
            self.oldPath = oldPath
        }
    }

    // MARK: - Internals

    /// `a/foo` → `foo`, `b/foo` → `foo`, `/dev/null` → `nil`. Strips a trailing `\t` git adds for paths with spaces.
    static func stripPathPrefix(_ raw: String) -> String? {
        var text = raw
        while text.hasSuffix("\t") { text.removeLast() }
        if text == "/dev/null" { return nil }
        if text.hasPrefix("a/") || text.hasPrefix("b/") { return String(text.dropFirst(2)) }
        return text
    }

    /// Splits `a/<p> b/<p>` (same path both sides) from a `diff --git` header; `nil` for renames (paths differ).
    static func samePath(fromGitHeader rest: String) -> String? {
        // "a/" + p + " b/" + p → count = 2n + 5
        let count = rest.count
        guard count >= 5, (count - 5) % 2 == 0 else { return nil }
        let n = (count - 5) / 2
        let candidate = String(rest.dropFirst(2).prefix(n))
        return rest == "a/\(candidate) b/\(candidate)" ? candidate : nil
    }

    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // @@ -12,7 +12,8 @@ optional
        guard line.hasPrefix("@@ ") else { return nil }
        let body = line.dropFirst(3)
        guard let end = body.range(of: " @@") else { return nil }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2 else { return nil }
        func parse(_ token: Substring, sign: Character) -> (Int, Int)? {
            guard token.first == sign else { return nil }
            let parts = token.dropFirst().split(separator: ",")
            guard let start = Int(parts[0]) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = parse(ranges[0], sign: "-"), let new = parse(ranges[1], sign: "+") else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    private struct FileBuilder {
        let gitHeader: String
        var oldHeader: String??   // outer nil: not seen; inner nil: /dev/null
        var newHeader: String??
        var renameFrom: String?
        var renameTo: String?
        var isNew = false
        var isDeleted = false
        var isBinary = false
        var hunks: [DiffHunk] = []
        var inHunk = false
        private var oldLine = 0
        private var newLine = 0

        init(gitHeader: String) { self.gitHeader = gitHeader }

        mutating func startHunk(_ line: String) {
            guard let header = DiffParser.parseHunkHeader(line) else { return }
            hunks.append(DiffHunk(header: line, oldStart: header.oldStart, oldCount: header.oldCount,
                                  newStart: header.newStart, newCount: header.newCount))
            oldLine = header.oldStart
            newLine = header.newStart
            inHunk = true
        }

        mutating func appendHunkLine(_ line: String) {
            guard !hunks.isEmpty else { return }
            let text = String(line.dropFirst())
            let entry: DiffLine
            switch line.first {
            case "+":
                entry = DiffLine(kind: .addition, text: text, newLineNumber: newLine)
                newLine += 1
            case "-":
                entry = DiffLine(kind: .deletion, text: text, oldLineNumber: oldLine)
                oldLine += 1
            case "\\":
                entry = DiffLine(kind: .noNewline, text: text.trimmingCharacters(in: .whitespaces))
            default:
                entry = DiffLine(kind: .context, text: text, oldLineNumber: oldLine, newLineNumber: newLine)
                oldLine += 1
                newLine += 1
            }
            hunks[hunks.count - 1].lines.append(entry)
        }

        func build() -> DiffFile? {
            let newPath = newHeader ?? nil
            let oldPath = oldHeader ?? nil
            let renamed = renameFrom != nil && renameTo != nil
            let path = renameTo ?? newPath ?? oldPath ?? DiffParser.samePath(fromGitHeader: gitHeader)
                ?? String(gitHeader.split(separator: " ").last.map { $0.hasPrefix("b/") ? $0.dropFirst(2) : $0[...] } ?? "")
            guard !path.isEmpty else { return nil }

            let status: DiffFile.Status
            if isBinary { status = .binary }
            else if isNew || (oldHeader != nil && oldPath == nil && newPath != nil) { status = .added }
            else if isDeleted || (newHeader != nil && newPath == nil && oldPath != nil) { status = .deleted }
            else if renamed { status = .renamed }
            else { status = .modified }

            let additions = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
            let deletions = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
            return DiffFile(
                path: path,
                oldPath: renamed ? renameFrom : nil,
                status: status,
                additions: additions,
                deletions: deletions,
                hunks: hunks
            )
        }
    }
}
