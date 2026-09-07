import Foundation

/// A git checkout found on disk by ``RepoDiscovery``.
public struct DiscoveredRepo: Sendable, Equatable, Hashable {
    /// How the checkout is materialised on disk.
    public enum GitKind: Sendable, Equatable, Hashable {
        /// A regular clone: `.git/` is a directory.
        case directory
        /// A worktree or a submodule: `.git` is a file whose `gitdir:` line points at the real git directory.
        case file(gitdir: String)
    }

    /// Absolute location of the working tree.
    public let url: URL
    /// Whether `.git` is a directory or a `gitdir:` file.
    public let kind: GitKind
    /// Distance from the scope root: 0 for the root itself, 1 for a direct child, and so on.
    public let depth: Int
    /// Path relative to the scope root: `""` for a repo-scope root, else `"api"`, `"deep/nested"`.
    public let relativePath: String
    /// `true` when this repo lies inside another discovered repo (submodule, vendored checkout).
    /// The M0 sidebar only shows primary repos; secondary ones are kept for the graph.
    public let isSecondary: Bool

    /// Creates a discovered repo. `relativePath` is expressed with `/` separators and no leading slash.
    public init(url: URL, kind: GitKind, depth: Int, relativePath: String, isSecondary: Bool = false) {
        self.url = url
        self.kind = kind
        self.depth = depth
        self.relativePath = relativePath
        self.isSecondary = isSecondary
    }

    /// The real git directory, usable to read `config` and `HEAD` without spawning git.
    ///
    /// For a worktree this is `<common>/worktrees/<name>`; the shared `config` lives in the common
    /// directory (see ``GitConfigReader``, which follows the `commondir` file).
    public var gitDirectory: URL {
        switch kind {
        case .directory:
            return url.appending(path: ".git")
        case .file(let gitdir):
            if gitdir.hasPrefix("/") {
                return URL(fileURLWithPath: gitdir, isDirectory: true)
            }
            return url.appending(path: gitdir).standardizedFileURL
        }
    }

    /// `true` for the repo that *is* the scope root (a "repo scope").
    public var isScopeRoot: Bool { depth == 0 }
}

/// Synchronous, stat-based scan of a scope folder for git checkouts.
///
/// Rules:
/// - Hidden folders (dotfiles, Finder-hidden) are never entered.
/// - Symbolic links are skipped unless ``followSymlinks`` is set; resolved paths are deduplicated either way.
/// - When the root itself is a repo it is reported at depth 0 and the walk continues *inside* it up to
///   ``maxDepth``: nested checkouts (submodules, vendored repos) are reported with `isSecondary == true`.
/// - A repo found below the root is a leaf unless ``descendIntoRepos`` is set; repos found inside it are secondary.
///
/// `scan` blocks on the file system: call it from `Task.detached`.
public struct RepoDiscovery: Sendable {
    /// Deepest folder level to inspect, relative to the root (0 = only the root itself).
    public var maxDepth: Int
    /// Enter symlinked folders (deduplicated by resolved path).
    public var followSymlinks: Bool
    /// Keep walking inside repos found below the root (their nested repos become secondary).
    public var descendIntoRepos: Bool

    public init(maxDepth: Int = 1, followSymlinks: Bool = false, descendIntoRepos: Bool = false) {
        self.maxDepth = maxDepth
        self.followSymlinks = followSymlinks
        self.descendIntoRepos = descendIntoRepos
    }

    /// Walks `root` and returns every checkout found, sorted by relative path (a repo-scope root first). Blocking.
    public func scan(_ root: URL) -> [DiscoveredRepo] {
        var found: [DiscoveredRepo] = []
        var visited: Set<String> = [root.resolvingSymlinksInPath().path]
        var rootIsRepo = false
        if let kind = Self.gitKind(at: root) {
            found.append(DiscoveredRepo(url: root, kind: kind, depth: 0, relativePath: "", isSecondary: false))
            rootIsRepo = true
        }
        walk(root, depth: 1, components: [], insideRepo: rootIsRepo, found: &found, visited: &visited)
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private func walk(_ directory: URL, depth: Int, components: [String], insideRepo: Bool,
                      found: inout [DiscoveredRepo], visited: inout Set<String>) {
        guard depth <= maxDepth else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }

        // Deterministic order so that symlink deduplication is stable (`api` wins over `link -> api`).
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true, !followSymlinks { continue }
            // `isDirectory` follows symlinks, so a symlinked folder counts as a folder here.
            guard values.isDirectory == true else { continue }
            let resolved = child.resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { continue }

            let childComponents = components + [child.lastPathComponent]
            var childInsideRepo = insideRepo
            if let kind = Self.gitKind(at: child) {
                found.append(DiscoveredRepo(url: child, kind: kind, depth: depth,
                                            relativePath: childComponents.joined(separator: "/"),
                                            isSecondary: insideRepo))
                guard descendIntoRepos else { continue }
                childInsideRepo = true
            }
            walk(child, depth: depth + 1, components: childComponents, insideRepo: childInsideRepo,
                 found: &found, visited: &visited)
        }
    }

    /// Detects `.git` as a directory (clone) or as a `gitdir:` file (worktree / submodule). `nil` when absent.
    public static func gitKind(at folder: URL) -> DiscoveredRepo.GitKind? {
        let dotGit = folder.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return .directory }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !gitdir.isEmpty else { return nil }
        return .file(gitdir: gitdir)
    }
}

/// What a scope folder turned out to be once scanned.
public enum ScopeKind: String, Sendable, Codable {
    /// The root folder is itself a git checkout.
    case repo
    /// The root folder contains one or more checkouts.
    case multiRepo
    /// A plain folder with no checkout in range.
    case plain
    /// The root folder does not exist (unmounted volume, deleted, moved).
    case missing
}

public extension ScopeKind {
    /// Classifies a scan result. Secondary repos never change the answer on their own.
    static func classify(rootExists: Bool, repos: [DiscoveredRepo]) -> ScopeKind {
        guard rootExists else { return .missing }
        if repos.contains(where: { $0.depth == 0 }) { return .repo }
        if repos.contains(where: { !$0.isSecondary }) { return .multiRepo }
        return .plain
    }
}
