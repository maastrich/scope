import Darwin
import Foundation

/// Works out which untracked files of a base checkout (`.env`, `.env.local`…) are copied into a new sandbox, and
/// copies them. A worktree starts from the committed tree, so the files a repository keeps out of git on purpose
/// are exactly the ones a fresh sandbox lacks.
///
/// Every glob is relative to the checkout, and wildcards are only allowed in the file name: `.env*`,
/// `apps/web/.env.local`, `config/*.local.json`. The plan refuses — never follows — anything that would read
/// outside the base checkout or write outside the sandbox: `..`, absolute globs, a source that is a symlink out of
/// the checkout, a destination with a symlink on its path. A destination that already exists (a tracked
/// `.env.example`) is left alone.
public enum SandboxFileCopy {
    public struct Copy: Sendable, Equatable {
        public var source: URL
        public var destination: URL
        /// Path relative to both roots.
        public var relativePath: String
    }

    public struct Refusal: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    public struct Plan: Sendable, Equatable {
        public var copies: [Copy] = []
        public var refusals: [Refusal] = []
    }

    public static func plan(globs: [String], base: URL, sandbox: URL) -> Plan {
        var plan = Plan()
        let baseRoot = realPath(base) ?? base.standardizedFileURL.path
        var seen = Set<String>()
        for raw in globs {
            let glob = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !glob.isEmpty else { continue }
            if glob.hasPrefix("/") || glob.hasPrefix("~") {
                plan.refusals.append(Refusal(path: glob, reason: "globs are relative to the repository"))
                continue
            }
            let components = glob.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if components.contains("..") {
                plan.refusals.append(Refusal(path: glob, reason: "“..” would leave the repository"))
                continue
            }
            let directories = components.dropLast().filter { $0 != "." }
            if directories.contains(where: isPattern) {
                plan.refusals.append(Refusal(path: glob, reason: "wildcards are only allowed in the file name"))
                continue
            }
            guard let pattern = components.last else { continue }
            let directory = directories.joined(separator: "/")
            let sourceDirectory = directory.isEmpty ? base : base.appending(path: directory, directoryHint: .isDirectory)
            let names: [String]
            if isPattern(pattern) {
                names = ((try? FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)) ?? [])
                    // FNM_PERIOD: `*.json` does not pick up hidden files; `.env*` names its dot and does.
                    .filter { fnmatch(pattern, $0, FNM_PERIOD) == 0 }
                    .sorted()
            } else {
                names = [pattern]
            }
            for name in names {
                let relative = directory.isEmpty ? name : "\(directory)/\(name)"
                guard seen.insert(relative).inserted else { continue }
                let source = sourceDirectory.appending(path: name, directoryHint: .notDirectory)
                switch check(source: source, relative: relative, baseRoot: baseRoot, sandbox: sandbox) {
                case .copy(let destination):
                    plan.copies.append(Copy(source: source, destination: destination, relativePath: relative))
                case .refuse(let reason):
                    plan.refusals.append(Refusal(path: relative, reason: reason))
                case .skip:
                    break
                }
            }
        }
        return plan
    }

    /// Where a repository keeps the skills, slash commands and subagents Claude Code loads for it.
    public static let driverResourceFolders = [".claude/skills", ".claude/commands", ".claude/agents"]

    /// The entries of `folders` the base checkout has and the sandbox lacks — a skill folder, a command file —
    /// each copied whole. They are there when a repository keeps them out of git (an ignored `.claude/`): Claude
    /// Code finds the main checkout's own from a worktree it starts in, but not from one it is handed with
    /// `--add-dir`, which is how the threads of a task of several repositories see each sandbox. Copied rather
    /// than linked, so an agent editing a skill edits the sandbox's copy, never the user's checkout. Never
    /// `settings.local.json` and the like: permission grants stay with the checkout unless `copyFiles` names them.
    ///
    /// The same refusals as `plan(globs:)`: a source leading out of the checkout, a sandbox path with a symlink on
    /// it. A folder holding a link that would still point at the checkout once copied (absolute, or leading out of
    /// the entry) is refused too.
    public static func planResources(folders: [String] = driverResourceFolders, base: URL, sandbox: URL) -> Plan {
        var plan = Plan()
        let baseRoot = realPath(base) ?? base.standardizedFileURL.path
        for folder in folders {
            let sourceFolder = base.appending(path: folder, directoryHint: .isDirectory)
            guard let resolvedFolder = realPath(sourceFolder) else { continue }
            guard isInside(resolvedFolder, root: baseRoot) else {
                plan.refusals.append(Refusal(path: folder, reason: "resolves outside the repository"))
                continue
            }
            guard isDirectory(resolvedFolder) else { continue }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: resolvedFolder)) ?? []).sorted()
            for name in names where name != ".DS_Store" {
                let relative = "\(folder)/\(name)"
                guard let resolved = realPath(sourceFolder.appending(path: name)), isInside(resolved, root: baseRoot) else {
                    plan.refusals.append(Refusal(path: relative, reason: "a symlink that leads out of the repository"))
                    continue
                }
                if isDirectory(resolved), let link = linkLeavingEntry(resolved) {
                    plan.refusals.append(Refusal(path: relative, reason: "holds a symlink (\(link)) that would still lead to the checkout"))
                    continue
                }
                switch destination(for: relative, in: sandbox) {
                case .copy(let destination):
                    plan.copies.append(Copy(source: URL(fileURLWithPath: resolved), destination: destination, relativePath: relative))
                case .refuse(let reason):
                    plan.refusals.append(Refusal(path: relative, reason: reason))
                case .skip:
                    break
                }
            }
        }
        return plan
    }

    /// Carries the plan out. Returns the relative paths copied, and the ones that failed with why.
    public static func apply(_ plan: Plan) -> (copied: [String], failed: [Refusal]) {
        var copied: [String] = []
        var failed: [Refusal] = []
        for copy in plan.copies {
            do {
                try FileManager.default.createDirectory(at: copy.destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: copy.source, to: copy.destination)
                copied.append(copy.relativePath)
            } catch {
                failed.append(Refusal(path: copy.relativePath, reason: error.localizedDescription))
            }
        }
        return (copied, failed)
    }

    private enum Verdict { case copy(URL), refuse(String), skip }

    private static func check(source: URL, relative: String, baseRoot: String, sandbox: URL) -> Verdict {
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            // A literal path that is not there: nothing to copy, nothing to complain about.
            return .skip
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            guard let target = realPath(source), isInside(target, root: baseRoot) else {
                return .refuse("a symlink that leads out of the repository")
            }
        }
        guard let resolved = realPath(source), isInside(resolved, root: baseRoot) else {
            return .refuse("resolves outside the repository")
        }
        var targetInfo = stat()
        guard stat(resolved, &targetInfo) == 0, (targetInfo.st_mode & S_IFMT) == S_IFREG else { return .skip }
        return destination(for: relative, in: sandbox)
    }

    private static func destination(for relative: String, in sandbox: URL) -> Verdict {
        // Every existing component from the sandbox down must be a real directory or file: a symlink there would
        // carry the copy somewhere else.
        let components = relative.split(separator: "/").map(String.init)
        var cursor = sandbox
        for (index, component) in components.enumerated() {
            cursor = cursor.appending(path: component)
            var node = stat()
            guard lstat(cursor.path, &node) == 0 else { continue }
            if (node.st_mode & S_IFMT) == S_IFLNK { return .refuse("the sandbox has a symlink on that path") }
            // Already there: a tracked file, or one copied before. Never overwritten.
            if index == components.count - 1 { return .skip }
        }
        return .copy(sandbox.appending(path: relative, directoryHint: .notDirectory))
    }

    /// The first link under `directory` that is absolute or resolves outside it, relative to `directory`.
    private static func linkLeavingEntry(_ directory: String) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: directory) else { return nil }
        while let relative = walker.nextObject() as? String {
            let path = directory + "/" + relative
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
            guard !target.hasPrefix("/"), let resolved = realpath(path, nil) else { return relative }
            defer { free(resolved) }
            if !isInside(String(cString: resolved), root: directory) { return relative }
        }
        return nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isPattern(_ text: String) -> Bool {
        text.contains { "*?[".contains($0) }
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
