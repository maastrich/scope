import Foundation

/// Where a file link clicked in a thread's terminal points: which file, which line, and which copy of it.
///
/// An agent prints paths as it sees them: absolute, `file://` (OSC 8), or relative to wherever it stands — and in a
/// task over several repositories it often leaves the repository's name out. The resolver turns such a link into the
/// files it can mean, the most likely first, so the viewer shows the task's version of a file rather than handing
/// the path to the Finder.
public enum FileLinkResolver {
    /// One repository the link may live in: its task sandbox (when a task is selected) and its base checkout.
    public struct Root: Sendable, Equatable {
        public var name: String
        public var sandbox: String?
        public var base: String

        public init(name: String, sandbox: String?, base: String) {
            self.name = name
            self.sandbox = sandbox
            self.base = base
        }
    }

    /// Which copy of a file a candidate is.
    public enum Origin: Sendable, Equatable {
        /// In the task's sandbox of `repo`: the version the agent is working on.
        case task(repo: String)
        /// In the base checkout of `repo`.
        case base(repo: String)
        /// Anywhere else on disk.
        case external
    }

    public struct Candidate: Sendable, Equatable {
        public var path: String
        public var origin: Origin
        /// Path inside its repository (`nil` for an external file).
        public var relativePath: String?

        public init(path: String, origin: Origin, relativePath: String?) {
            self.path = path
            self.origin = origin
            self.relativePath = relativePath
        }
    }

    public struct Resolution: Sendable, Equatable {
        public var candidates: [Candidate]
        public var line: Int?
        public var column: Int?
    }

    /// The link's path and its `:line[:column]` (or `#L12`) suffix, `file://` and `~` undone; `nil` for a link that is
    /// not a file (a web URL, a mail address).
    public static func parse(_ link: String) -> (path: String, line: Int?, column: Int?)? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Punctuation a sentence wraps a path in, kept by implicit detection.
        while let last = text.last, ".,;)]'\"`".contains(last) { text.removeLast() }
        while let first = text.first, "(['\"`".contains(first) { text.removeFirst() }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            guard scheme == "file" else { return nil }
            text = url.path(percentEncoded: false)
            if let fragment = url.fragment, fragment.hasPrefix("L"), let line = Int(fragment.dropFirst()) {
                return (text, line, nil)
            }
        }
        var line: Int?
        var column: Int?
        if let match = text.range(of: #":([0-9]+)(?::([0-9]+))?$"#, options: .regularExpression) {
            let numbers = text[match].dropFirst().split(separator: ":").compactMap { Int($0) }
            line = numbers.first
            column = numbers.count > 1 ? numbers[1] : nil
            text = String(text[..<match.lowerBound])
        }
        if text.hasPrefix("~") { text = (text as NSString).expandingTildeInPath }
        guard !text.isEmpty else { return nil }
        return (text, line, column)
    }

    /// The files `link` can mean, most likely first; empty when it names nothing on disk.
    ///
    /// An absolute path is classified by where it lies. A relative one is tried from the thread's directory, then at
    /// the root of every repository — in its sandbox while a task is selected, in its base checkout otherwise — the
    /// thread's own repository first.
    public static func resolve(_ link: String, threadDirectory: String?, roots: [Root],
                               fileExists: (String) -> Bool) -> Resolution? {
        guard let parsed = parse(link) else { return nil }
        // `/tmp` and `/private/tmp` are one folder: compare the resolved forms, or a sandbox under a symlink reads as
        // "elsewhere on disk".
        let roots = roots.map { Root(name: $0.name, sandbox: $0.sandbox.map(standardized), base: standardized($0.base)) }
        let threadDirectory = threadDirectory.map(standardized)
        var tried: [String] = []
        if parsed.path.hasPrefix("/") {
            tried = [standardized(parsed.path)]
        } else {
            if let threadDirectory { tried.append(standardized(threadDirectory + "/" + parsed.path)) }
            let ordered = roots.sorted { lhs, rhs in
                contains(threadDirectory, lhs) && !contains(threadDirectory, rhs)
            }
            for root in ordered {
                tried.append(standardized((root.sandbox ?? root.base) + "/" + parsed.path))
            }
        }
        var seen: Set<String> = []
        let candidates = tried
            .filter { seen.insert($0).inserted && fileExists($0) }
            .map { classify($0, roots: roots) }
        return Resolution(candidates: candidates, line: parsed.line, column: parsed.column)
    }

    static func classify(_ path: String, roots: [Root]) -> Candidate {
        // The deepest root wins: a repository nested in a scope-root repository is its own.
        var best: (candidate: Candidate, depth: Int)?
        for root in roots {
            for (folder, origin) in [(root.sandbox, Origin.task(repo: root.name)), (Optional(root.base), Origin.base(repo: root.name))] {
                guard let folder, let relative = relativePath(path, in: folder) else { continue }
                if best == nil || folder.count > best!.depth {
                    best = (Candidate(path: path, origin: origin, relativePath: relative), folder.count)
                }
            }
        }
        return best?.candidate ?? Candidate(path: path, origin: .external, relativePath: nil)
    }

    private static func contains(_ directory: String?, _ root: Root) -> Bool {
        guard let directory else { return false }
        return [root.sandbox, root.base].compactMap { $0 }.contains { relativePath(directory, in: $0) != nil || directory == $0 }
    }

    private static func relativePath(_ path: String, in folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
