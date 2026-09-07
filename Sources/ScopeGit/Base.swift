import Foundation
import ScopeCore

/// Failures of the Base view helpers (spec §4.5) that are not plain git errors.
public enum BaseError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `pullFastForward` on a branch that diverged from its upstream.
    case diverged(branch: String, upstream: String)
    /// `pullFastForward` / `behindCount` on a detached HEAD or without a default branch.
    case noBranch
    /// `readFile` on a file that does not look like text.
    case binaryFile(path: String)
    /// `readFile` on a file larger than `BaseFiles.maxReadBytes`.
    case fileTooLarge(path: String, bytes: Int)
    /// `readFile` on a missing file or a directory.
    case notAFile(path: String)

    public var description: String {
        switch self {
        case .diverged(let branch, let upstream): "\(branch) and \(upstream) have diverged; a fast-forward pull is not possible"
        case .noBranch: "not on a branch"
        case .binaryFile(let path): "\(path) is a binary file"
        case .fileTooLarge(let path, let bytes): "\(path) is too large to display (\(bytes) bytes)"
        case .notAFile(let path): "\(path) is not a regular file"
        }
    }
}

/// One line of `recentHistory`.
public struct Commit: Sendable, Equatable, Hashable, Identifiable {
    public var sha: String
    public var short: String
    public var subject: String
    public var author: String
    public var date: Date

    public var id: String { sha }

    public init(sha: String, short: String, subject: String, author: String, date: Date) {
        self.sha = sha
        self.short = short
        self.subject = subject
        self.author = author
        self.date = date
    }
}

/// A node of `fileTree`: directories first, then files, both sorted by name.
public struct FileNode: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    /// Path relative to the repository root (`""` for the root itself).
    public var path: String
    public var isDirectory: Bool
    public var children: [FileNode]

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, children: [FileNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Builds a tree from relative file paths (`a/b.txt`).
    public static func tree(paths: [String]) -> FileNode {
        final class Builder {
            var dirs: [String: Builder] = [:]
            var files: Set<String> = []
        }
        let root = Builder()
        for path in paths where !path.isEmpty {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let file = parts.last else { continue }
            var node = root
            for dir in parts.dropLast() {
                if let next = node.dirs[dir] {
                    node = next
                } else {
                    let next = Builder()
                    node.dirs[dir] = next
                    node = next
                }
            }
            node.files.insert(file)
        }
        func render(_ builder: Builder, name: String, path: String) -> FileNode {
            let dirs = builder.dirs.keys.sorted().map { dir in
                render(builder.dirs[dir]!, name: dir, path: path.isEmpty ? dir : "\(path)/\(dir)")
            }
            let files = builder.files.sorted().map { file in
                FileNode(name: file, path: path.isEmpty ? file : "\(path)/\(file)", isDirectory: false)
            }
            return FileNode(name: name, path: path, isDirectory: true, children: dirs + files)
        }
        return render(root, name: "", path: "")
    }

    /// Every file path of the subtree, depth first.
    public var filePaths: [String] {
        isDirectory ? children.flatMap(\.filePaths) : [path]
    }
}

/// One hit of `search`.
public struct SearchMatch: Sendable, Equatable, Hashable {
    public var path: String
    /// 1-based.
    public var line: Int
    public var text: String
    /// Character ranges of the matched substrings inside `text` (`rg --json` submatches; computed for `git grep`).
    public var submatches: [Range<Int>]

    public init(path: String, line: Int, text: String, submatches: [Range<Int>] = []) {
        self.path = path
        self.line = line
        self.text = text
        self.submatches = submatches
    }

    /// Character ranges where `pattern` occurs in `text` (regex or literal, case and whole-word aware).
    public static func ranges(of pattern: String, in text: String, options: BaseSearchOptions) -> [Range<Int>] {
        let chars = Array(text)
        var ranges: [Range<Int>] = []
        if options.regex {
            var regexOptions: NSRegularExpression.Options = []
            if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
            let source = options.wholeWord ? "\\b(?:\(pattern))\\b" : pattern
            guard let regex = try? NSRegularExpression(pattern: source, options: regexOptions) else { return [] }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
                guard let range = Range(match.range, in: text) else { continue }
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                ranges.append(start..<end)
            }
            return ranges
        }
        let needle = Array(options.caseSensitive ? pattern : pattern.lowercased())
        let hay = options.caseSensitive ? chars : Array(text.lowercased())
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var index = 0
        while index + needle.count <= hay.count {
            if Array(hay[index..<index + needle.count]) == needle {
                let end = index + needle.count
                let boundaryBefore = index == 0 || !Self.isWord(hay[index - 1])
                let boundaryAfter = end == hay.count || !Self.isWord(hay[end])
                if !options.wholeWord || (boundaryBefore && boundaryAfter) {
                    ranges.append(index..<end)
                    index = end
                    continue
                }
            }
            index += 1
        }
        return ranges
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

/// How `search` interprets its pattern. Defaults match `rg`: case-sensitive, regex, no word boundaries.
public struct BaseSearchOptions: Sendable, Equatable, Hashable {
    public var caseSensitive: Bool
    /// `false` searches the pattern literally (`-F`).
    public var regex: Bool
    /// `-w`: matches surrounded by non-word characters only.
    public var wholeWord: Bool

    public init(caseSensitive: Bool = true, regex: Bool = true, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}

/// Which tool `search` uses.
public enum SearchTool: Sendable, Equatable {
    /// `rg --json` at this absolute path.
    case ripgrep(String)
    /// `git grep -n` (tracked and untracked files, `.gitignore` respected).
    case gitGrep

    /// Short label for the UI ("rg" / "git grep").
    public var displayName: String {
        switch self {
        case .ripgrep: "rg"
        case .gitGrep: "git grep"
        }
    }

    /// `.ripgrep` when `rg` is on `PATH` or at the usual Homebrew locations, else `.gitGrep`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> SearchTool {
        var candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/rg" }
        candidates += ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return .ripgrep(candidate)
        }
        return .gitGrep
    }
}

/// Base view operations (spec §4.5). Every call runs on the repository's serial queue.
public extension GitClient {
    /// `git pull --ff-only <remote> <branch>` (the current branch by default).
    /// Throws `BaseError.diverged` when a fast-forward is impossible, `BaseError.noBranch` on a detached HEAD.
    func pullFastForward(remote: String = "origin", branch: String? = nil, timeout: Duration? = .seconds(180)) async throws {
        let current = try await output(["rev-parse", "--abbrev-ref", "HEAD"], timeout: .seconds(10))
        guard current != "HEAD" else { throw BaseError.noBranch }
        let target = branch ?? current
        // `--no-rebase`: a `pull.rebase` config would otherwise refuse the pull on a dirty tree before trying the fast-forward.
        let result = try await run(["pull", "--ff-only", "--no-rebase", "--quiet", remote, target], timeout: timeout, allowFailure: true)
        guard !result.succeeded else { return }
        let stderr = result.stderrText.lowercased()
        if stderr.contains("fast-forward") || stderr.contains("diverg") {
            throw BaseError.diverged(branch: current, upstream: "\(remote)/\(target)")
        }
        throw GitError(arguments: ["pull", "--ff-only", "--no-rebase", remote, target], result: result)
    }

    /// Commits `<remote>/<branch>` has that `HEAD` has not, after an optional `git fetch`.
    /// `branch` defaults to the repository's default branch (`BaseError.noBranch` when unknown).
    func behindCount(remote: String = "origin", branch: String? = nil, fetch: Bool = true) async throws -> Int {
        let resolved: String?
        if let branch { resolved = branch } else { resolved = await defaultBranch() }
        guard let target = resolved else { throw BaseError.noBranch }
        if fetch { try await self.fetch(remote: remote) }
        let count = try await output(["rev-list", "--count", "HEAD..\(remote)/\(target)"], timeout: .seconds(30))
        return Int(count) ?? 0
    }

    /// The last `limit` commits of `HEAD`, newest first.
    func recentHistory(limit: Int = 30) async throws -> [Commit] {
        let text = try await run(["log", "-n", String(max(1, limit)), "--format=%H%x1f%h%x1f%s%x1f%an%x1f%cI%x1e"], timeout: .seconds(30)).stdoutText
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 5, let date = formatter.date(from: String(fields[4])) else { return nil }
            return Commit(sha: String(fields[0]), short: String(fields[1]), subject: String(fields[2]), author: String(fields[3]), date: date)
        }
    }

    /// Tree of tracked and untracked files, `.gitignore` respected
    /// (`git ls-files --cached --others --exclude-standard`).
    func fileTree() async throws -> FileNode {
        let data = try await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: .seconds(60)).stdout
        let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return FileNode.tree(paths: paths)
    }

    /// Full-text search in the working tree, `.gitignore` respected. `subpath` restricts the search.
    /// No match is an empty array, not an error. Results are capped at `limit`.
    func search(
        pattern: String, in subpath: String? = nil, options: BaseSearchOptions = .init(), tool: SearchTool = .locate(), limit: Int = 500
    ) async throws -> [SearchMatch] {
        switch tool {
        case .ripgrep(let executable):
            var arguments = ["--json", "--max-count", "200", options.caseSensitive ? "-s" : "-i"]
            if !options.regex { arguments.append("-F") }
            if options.wholeWord { arguments.append("-w") }
            arguments += ["-e", pattern, "--", subpath ?? "."]
            let result = try await Subprocess.run(
                executable: executable, arguments: arguments, currentDirectory: repository,
                environment: ["LC_ALL": "C"], timeout: .seconds(60)
            )
            guard result.exitCode <= 1 else {
                throw GitError(arguments: ["rg"] + arguments, result: result)   // 2 = error
            }
            return Array(Self.parseRipgrepJSON(result.stdoutText).prefix(limit))
        case .gitGrep:
            var arguments = ["grep", "-n", "-I", "--untracked", options.regex ? "-E" : "-F"]
            if !options.caseSensitive { arguments.append("-i") }
            if options.wholeWord { arguments.append("-w") }
            arguments += ["-e", pattern]
            if let subpath { arguments += ["--", subpath] }
            let result = try await run(arguments, timeout: .seconds(60), allowFailure: true)
            guard result.exitCode <= 1 else { throw GitError(arguments: arguments, result: result) }
            let matches = Self.parseGrepLines(result.stdoutText).prefix(limit).map { match in
                var match = match
                match.submatches = SearchMatch.ranges(of: pattern, in: match.text, options: options)
                return match
            }
            return Array(matches)
        }
    }

    /// Reads a text file of the checkout (see `BaseFiles.readFile`).
    nonisolated func readFile(at relativePath: String) throws -> String {
        try BaseFiles.readFile(at: repository.appending(path: relativePath))
    }

    /// Lines of `rg --json`: keeps `"type":"match"` events.
    static func parseRipgrepJSON(_ text: String) -> [SearchMatch] {
        text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "match",
                  let data = object["data"] as? [String: Any],
                  let path = (data["path"] as? [String: Any])?["text"] as? String,
                  let number = data["line_number"] as? Int,
                  let matched = (data["lines"] as? [String: Any])?["text"] as? String
            else { return nil }
            let text = matched.trimmingCharacters(in: .newlines)
            // Submatch offsets are UTF-8 byte offsets in `lines.text`: map them to character offsets.
            let utf8 = Array(text.utf8)
            let submatches = ((data["submatches"] as? [[String: Any]]) ?? []).compactMap { sub -> Range<Int>? in
                guard let start = sub["start"] as? Int, let end = sub["end"] as? Int, start < end, end <= utf8.count else { return nil }
                let lower = String(decoding: utf8[..<start], as: UTF8.self).count
                let upper = lower + String(decoding: utf8[start..<end], as: UTF8.self).count
                return lower..<upper
            }
            return SearchMatch(path: Self.stripDotSlash(path), line: number, text: text, submatches: submatches)
        }
    }

    /// `path:line:text` lines of `git grep -n`.
    static func parseGrepLines(_ text: String) -> [SearchMatch] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return SearchMatch(path: String(parts[0]), line: number, text: String(parts[2]))
        }
    }

    private static func stripDotSlash(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }
}

/// Read-only file access for the Base viewer.
public enum BaseFiles {
    /// 1 MiB: larger files are refused with `BaseError.fileTooLarge`.
    public static let maxReadBytes = 1_048_576

    /// UTF-8 text of `url`. Throws `BaseError.notAFile`, `.fileTooLarge`, or `.binaryFile` (NUL byte in the
    /// first 8 KiB, or invalid UTF-8).
    public static func readFile(at url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BaseError.notAFile(path: url.path)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxReadBytes else { throw BaseError.fileTooLarge(path: url.path, bytes: size) }
        let data = try Data(contentsOf: url)
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else {
            throw BaseError.binaryFile(path: url.path)
        }
        return text
    }
}
