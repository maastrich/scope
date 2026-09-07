import Foundation

/// What a batch of file-system events means for a scope: rescan the folder tree, and/or refresh the
/// git facts of some repos. Produced by ``ScopeEventFilter``, coalesced by ``ScopeWatcher``.
public struct ScopeChangeHint: Sendable, Equatable {
    /// A folder or a `.git` appeared, disappeared or was renamed within discovery depth.
    public var rescan: Bool
    /// Events were dropped (`MustScanSubDirs`) or the root itself changed: rescan from scratch.
    public var fullRescan: Bool
    /// The scope root was moved or deleted. Also implies ``fullRescan``.
    public var rootChanged: Bool
    /// Relative paths of known repos whose facts (branch, dirty state) may have changed.
    public var touchedRepos: Set<String>

    public init(rescan: Bool = false, fullRescan: Bool = false, rootChanged: Bool = false,
                touchedRepos: Set<String> = []) {
        self.rescan = rescan
        self.fullRescan = fullRescan
        self.rootChanged = rootChanged
        self.touchedRepos = touchedRepos
    }

    /// The hint that asks for nothing.
    public static let none = ScopeChangeHint()

    /// `true` when nothing needs to happen.
    public var isEmpty: Bool { !rescan && !fullRescan && !rootChanged && touchedRepos.isEmpty }

    /// `true` when the folder tree should be walked again (either flavour).
    public var needsRescan: Bool { rescan || fullRescan || rootChanged }

    /// Union of two hints: flags are OR-ed, touched repos merged.
    public func merged(with other: ScopeChangeHint) -> ScopeChangeHint {
        ScopeChangeHint(rescan: rescan || other.rescan,
                        fullRescan: fullRescan || other.fullRescan,
                        rootChanged: rootChanged || other.rootChanged,
                        touchedRepos: touchedRepos.union(other.touchedRepos))
    }
}

/// Pure classifier from an ``FSEventBatch`` to a ``ScopeChangeHint``.
///
/// Rules (in order, per event):
/// 1. `MustScanSubDirs` → `fullRescan`; `RootChanged` → `fullRescan` + `rootChanged`.
/// 2. Paths outside the root are ignored; the root path itself only counts as touching a repo-scope root.
/// 3. Noise is dropped: `.DS_Store`, `*.lock`, atomic-write temp files (`*.sb-*`, `*~`, `.#*`),
///    and everything under `.git/objects/` or `.git/logs/`.
/// 4. A `.git` entry created, removed or renamed at a depth discovery would look at → `rescan`.
/// 5. A folder created, removed or renamed at relative depth ≤ `depth`, outside hidden folders → `rescan`.
/// 6. Any surviving event under a known repo → that repo (and every enclosing known repo) is touched.
public enum ScopeEventFilter {
    /// - Parameters:
    ///   - batch: events as delivered by ``FSEventsWatcher`` (paths are resolved by the system).
    ///   - root: the scope root as declared (any form; `/private` and symlinks are reconciled here).
    ///   - depth: the scope's discovery depth (folders deeper than this never trigger a rescan).
    ///   - knownRepos: relative paths of the repos currently displayed (`""` for a repo-scope root).
    public static func classify(_ batch: FSEventBatch, root: URL, depth: Int, knownRepos: Set<String>) -> ScopeChangeHint {
        var hint = ScopeChangeHint.none
        let roots = rootPrefixes(for: root)
        let known = knownRepos.map { $0.split(separator: "/").map(String.init) }

        for event in batch.events {
            if event.mustRescan { hint.fullRescan = true }
            if event.rootChanged {
                hint.fullRescan = true
                hint.rootChanged = true
                continue
            }
            guard let components = relativeComponents(of: event.path, roots: roots) else { continue }
            if components.isEmpty {
                // The root folder itself: its mtime changes when a direct child is added or removed; the
                // child event carries the useful information. Only a repo-scope root is "touched" by it.
                if knownRepos.contains("") { hint.touchedRepos.insert("") }
                continue
            }
            guard !isNoise(components) else { continue }

            if let last = components.last, last == ".git" {
                // `.git` appearing or vanishing changes the repo list, if discovery would look there.
                let parentDepth = components.count - 1
                let parentIsVisible = !components.dropLast().contains(where: { $0.hasPrefix(".") })
                if (event.created || event.removed || event.renamed), parentDepth <= depth, parentIsVisible {
                    hint.rescan = true
                }
            } else if event.isDirectory, event.created || event.removed || event.renamed,
                      components.count <= depth, !components.contains(where: { $0.hasPrefix(".") }) {
                hint.rescan = true
            }

            for repo in known where isPrefix(repo, of: components) {
                hint.touchedRepos.insert(repo.joined(separator: "/"))
            }
        }
        return hint
    }

    // MARK: - Helpers

    /// Path components of `path` relative to the root, or `nil` when the path is not under it.
    private static func relativeComponents(of path: String, roots: [String]) -> [String]? {
        for root in roots {
            if path == root { return [] }
            if path.hasPrefix(root + "/") {
                return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            }
        }
        return nil
    }

    /// The root path in every form FSEvents may report it: as declared, symlink-resolved, and with the
    /// `/private` prefix that `resolvingSymlinksInPath()` strips.
    private static func rootPrefixes(for root: URL) -> [String] {
        let declared = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().path
        var prefixes: [String] = []
        for base in [declared, resolved] {
            let trimmed = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
            for candidate in [trimmed, "/private" + trimmed] where !prefixes.contains(candidate) {
                prefixes.append(candidate)
            }
        }
        return prefixes
    }

    /// Editor / git / Finder noise that never changes what Scope displays.
    private static func isNoise(_ components: [String]) -> Bool {
        guard let last = components.last else { return true }
        if last == ".DS_Store" || last.hasSuffix(".lock") || last.hasSuffix("~")
            || last.hasPrefix(".#") || last.contains(".sb-") {
            return true
        }
        if let git = components.firstIndex(of: ".git"), git + 1 < components.count {
            let inside = components[git + 1]
            if inside == "objects" || inside == "logs" { return true }
        }
        return false
    }

    private static func isPrefix(_ prefix: [String], of components: [String]) -> Bool {
        prefix.count <= components.count && Array(components.prefix(prefix.count)) == prefix
    }
}
