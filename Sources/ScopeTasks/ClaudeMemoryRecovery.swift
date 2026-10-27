import Foundation

/// `scope memory`: finds the Claude Code memories that went astray before `ClaudeMemory` — a task root's, which
/// nothing reads once the task is archived, and another clone's of a scope repository — and copies them into the
/// memory of their repository or scope.
///
/// Nothing is ever deleted or overwritten. A file identical to one the target holds, or carrying the same `name`, is
/// a duplicate and is left out; a file whose name is taken by a different one is a conflict, listed for the user.
/// The plan is computed once, sources in a fixed order, so the dry run and `--apply` agree on every outcome.
public enum ClaudeMemoryRecovery {
    // MARK: Input

    /// A scope and its repositories, as the app knows them.
    public struct Scope: Sendable, Equatable {
        public var slug: String
        public var name: String
        /// The scope folder.
        public var root: String
        /// Base checkouts, relative to `root` (`"."` for a repo scope), with their `origin` remote when they have one.
        public var repos: [Repo]

        public init(slug: String, name: String, root: String, repos: [Repo]) {
            self.slug = slug
            self.name = name
            self.root = root
            self.repos = repos
        }
    }

    public struct Repo: Sendable, Equatable {
        public var relativePath: String
        public var remote: String?

        public init(relativePath: String, remote: String?) {
            self.relativePath = TaskRepo.normalize(relativePath)
            self.remote = remote
        }
    }

    /// The disk, injected so a test runs on a hand-made tree.
    public struct Disk: Sendable {
        /// Entry names of a folder, `nil` when it is not one.
        public var children: @Sendable (String) -> [String]?
        public var read: @Sendable (String) -> Data?
        /// The `origin` remote of the repository holding a folder, `nil` outside one or without a remote.
        public var remote: @Sendable (String) -> String?

        public init(children: @escaping @Sendable (String) -> [String]?, read: @escaping @Sendable (String) -> Data?,
                    remote: @escaping @Sendable (String) -> String?) {
            self.children = children
            self.read = read
            self.remote = remote
        }

        public static let live = Disk(
            children: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return try? FileManager.default.contentsOfDirectory(atPath: path)
            },
            read: { FileManager.default.contents(atPath: $0) },
            remote: { path in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", path, "config", "--get", "remote.origin.url"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        )
    }

    // MARK: Plan

    /// A memory folder things are copied into.
    public struct Target: Sendable, Equatable {
        public var scope: String
        /// The repository's name, or the scope's for its own memory.
        public var label: String
        public var owner: ClaudeMemory.Owner
        public var directory: String
    }

    /// Why a folder is a source.
    public enum Origin: Sendable, Equatable {
        /// The root of a task of several repositories (`slug`), or a folder of one that left no record (`nil`).
        case taskRoot(String?)
        /// A sandbox of a task, from a Claude Code that filed memory by working directory.
        case sandbox(String)
        /// Another clone of the repository, outside the scope.
        case otherClone(String)
    }

    public enum Outcome: Sendable, Equatable {
        /// Copied (written with `--apply`).
        case copy
        /// The target already has the same text, in the named file.
        case identical(String)
        /// The target already has a memory of this `name`, in the named file, with other text: kept as it is, listed.
        case sameName(String)
        /// The file name is taken by another memory: nothing copied, listed.
        case conflict
    }

    public struct FileAction: Sendable, Equatable {
        public var file: String
        public var outcome: Outcome
    }

    public struct Source: Sendable, Equatable {
        /// The folder under `<config>/projects/`.
        public var folder: String
        public var origin: Origin
        public var files: [FileAction]
        /// Lines added to the target's `MEMORY.md`, one per copied file.
        public var indexLines: [String]
    }

    public struct TargetPlan: Sendable, Equatable {
        public var target: Target
        public var sources: [Source]
        /// The target's `MEMORY.md` once merged.
        public var indexLineCount: Int
        public var indexByteCount: Int

        public var copies: Int { sources.reduce(0) { $0 + $1.files.filter { $0.outcome == .copy }.count } }
        /// Past Claude Code's load limit (200 lines or 25 kB), the end of the index is dropped at every session start.
        public var indexOverLimit: Bool { indexLineCount > 200 || indexByteCount > 25_000 }
    }

    public struct Plan: Sendable, Equatable {
        public var targets: [TargetPlan]
        /// Memory folders that belong to no scope, left alone.
        public var leftAlone: [String]
    }

    /// The plan for every memory folder under `locator.projectsDirectory`.
    ///
    /// A folder is matched by encoding the paths Scope knows — scope roots, base checkouts, every task root and
    /// sandbox, archived ones included — never by decoding its name; one that matches none and sits under
    /// `sandboxesRoot/<scope slug>` is a task root whose record is gone, and any other is looked up on the disk
    /// and matched to a scope repository by its remote.
    public static func plan(locator: ClaudeMemory.Locator, sandboxesRoot: String, scopes: [Scope], tasks: [TaskRecord],
                            disk: Disk = .live) -> Plan {
        let projects = locator.projectsDirectory.filesystemPath
        var targets: [String: Target] = [:]   // folder name → target
        var byRemote: [String: Target] = [:]
        var scopeTargets: [String: Target] = [:]   // scope root → its target
        for scope in scopes {
            let scopeTarget = target(scope: scope, owner: .scope, label: scope.name, path: scope.root, locator: locator)
            targets[folderName(scope.root)] = scopeTarget
            scopeTargets[ClaudeMemory.canonicalPath(scope.root)] = scopeTarget
            for repo in scope.repos {
                let path = repo.relativePath == "." ? scope.root : (scope.root as NSString).appendingPathComponent(repo.relativePath)
                let repoTarget = target(scope: scope, owner: .repository(repo.relativePath),
                                        label: repo.relativePath == "." ? scope.name : repo.relativePath, path: path, locator: locator)
                targets[folderName(path)] = repoTarget
                if let remote = repo.remote.flatMap(normalizedRemote) { byRemote[remote] = byRemote[remote] ?? repoTarget }
            }
        }

        // Every path a task ever started threads in.
        var known: [String: (Target, Origin)] = [:]
        for task in tasks {
            guard let scopeTarget = scopeTargets[ClaudeMemory.canonicalPath(task.scopeRoot)] else { continue }
            known[folderName(task.root)] = known[folderName(task.root)] ?? (scopeTarget, .taskRoot(task.slug))
            for sandbox in task.sandboxes {
                let repoName = folderName(sandbox.repoRelativePath == "."
                                          ? task.scopeRoot : (task.scopeRoot as NSString).appendingPathComponent(sandbox.repoRelativePath))
                let repoTarget = targets[repoName] ?? scopeTarget
                known[folderName(sandbox.sandboxPath)] = known[folderName(sandbox.sandboxPath)] ?? (repoTarget, .sandbox(task.slug))
            }
        }
        let sandboxPrefixes = scopes.compactMap { scope -> (String, Target)? in
            guard let target = scopeTargets[ClaudeMemory.canonicalPath(scope.root)] else { return nil }
            return (folderName((sandboxesRoot as NSString).appendingPathComponent(scope.slug)) + "-", target)
        }

        var sources: [String: [(String, Origin)]] = [:]   // target directory → sources
        var targetByDirectory: [String: Target] = [:]
        var leftAlone: [String] = []
        for folder in (disk.children(projects) ?? []).sorted() {
            guard !memoryFiles(in: memoryPath(projects, folder), disk: disk).isEmpty else { continue }
            if targets[folder] != nil { continue }
            let match: (Target, Origin)?
            if let found = known[folder] {
                match = found
            } else if let prefix = sandboxPrefixes.first(where: { folder.hasPrefix($0.0) }) {
                match = (prefix.1, .taskRoot(nil))
            } else if let path = locate(folder: folder, disk: disk),
                      let remote = disk.remote(path).flatMap(normalizedRemote), let target = byRemote[remote] {
                match = (target, .otherClone(path))
            } else {
                match = nil
            }
            guard let (target, origin) = match else { leftAlone.append(folder); continue }
            sources[target.directory, default: []].append((folder, origin))
            targetByDirectory[target.directory] = target
        }

        let plans = targetByDirectory.values
            .sorted { ($0.scope, $0.owner == .scope ? 0 : 1, $0.label) < ($1.scope, $1.owner == .scope ? 0 : 1, $1.label) }
            .map { target in
                merge(target: target, sources: sources[target.directory] ?? [], projects: projects, disk: disk)
            }
        return Plan(targets: plans, leftAlone: leftAlone)
    }

    private static func target(scope: Scope, owner: ClaudeMemory.Owner, label: String, path: String,
                               locator: ClaudeMemory.Locator) -> Target {
        Target(scope: scope.name, label: label, owner: owner, directory: locator.memoryDirectory(forProject: path).filesystemPath)
    }

    static func folderName(_ path: String) -> String {
        ClaudeMemory.projectFolderName(ClaudeMemory.canonicalPath(path))
    }

    private static func memoryPath(_ projects: String, _ folder: String) -> String {
        (projects as NSString).appendingPathComponent(folder) + "/memory"
    }

    /// The memory files of a folder: its Markdown files but the index.
    static func memoryFiles(in directory: String, disk: Disk) -> [String] {
        (disk.children(directory) ?? []).filter { $0.hasSuffix(".md") && $0 != indexFile && !$0.hasPrefix(".") }.sorted()
    }

    static let indexFile = "MEMORY.md"

    /// `host/owner/repo`, lowercased, for `git@host:owner/repo.git`, `https://host/owner/repo` and `ssh://git@host/owner/repo`.
    static func normalizedRemote(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let at = text.firstIndex(of: "@"), text[..<at].contains(where: { $0 == "/" }) == false { text = String(text[text.index(after: at)...]) }
        if !remote.contains("://"), let colon = text.firstIndex(of: ":") { text.replaceSubrange(colon...colon, with: "/") }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }

    /// The path a project folder was named after, found by walking the disk from `/` into the children whose
    /// encoded path the name continues. `nil` when nothing on disk encodes to it any more (or it was cut to 200).
    static func locate(folder: String, disk: Disk) -> String? {
        guard folder.count <= ClaudeMemory.maxFolderNameLength else { return nil }
        func walk(_ path: String, depth: Int) -> String? {
            guard depth < 16 else { return nil }
            for child in (disk.children(path) ?? []).sorted() {
                let candidate = path == "/" ? "/" + child : path + "/" + child
                let name = ClaudeMemory.projectFolderName(candidate)
                if name == folder, disk.children(candidate) != nil { return candidate }
                if folder.hasPrefix(name + "-"), let found = walk(candidate, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk("/", depth: 0)
    }

    // MARK: Merge

    /// One memory file's `name:` from its front matter.
    static func memoryName(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard trimmed.hasPrefix("name:") else { continue }
            let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One memory file's `description:`, for an index line the source had none for.
    static func memoryDescription(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard trimmed.hasPrefix("description:") else { continue }
            let value = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func merge(target: Target, sources: [(String, Origin)], projects: String, disk: Disk) -> TargetPlan {
        // What the target holds, updated as the plan copies into it, so a later source sees an earlier one's files.
        var files: [String: Data] = [:]
        var names: [String: String] = [:]   // memory name → file
        for file in memoryFiles(in: target.directory, disk: disk) {
            guard let data = disk.read((target.directory as NSString).appendingPathComponent(file)) else { continue }
            files[file] = data
            if let name = memoryName(String(decoding: data, as: UTF8.self)) { names[name] = names[name] ?? file }
        }
        var index = disk.read((target.directory as NSString).appendingPathComponent(indexFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""

        var planned: [Source] = []
        for (folder, origin) in sources {
            let directory = memoryPath(projects, folder)
            let sourceIndex = disk.read((directory as NSString).appendingPathComponent(indexFile))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            var actions: [FileAction] = []
            var lines: [String] = []
            for file in memoryFiles(in: directory, disk: disk) {
                guard let data = disk.read((directory as NSString).appendingPathComponent(file)) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                let name = memoryName(text)
                let outcome: Outcome
                if files[file] == data {
                    outcome = .identical(file)
                } else if let twin = files.first(where: { $0.value == data })?.key {
                    outcome = .identical(twin)
                } else if let name, let existing = names[name] {
                    outcome = .sameName(existing)
                } else if files[file] != nil {
                    outcome = .conflict
                } else {
                    outcome = .copy
                    files[file] = data
                    if let name { names[name] = file }
                    if !index.contains("(\(file))") {
                        let line = sourceIndex.split(separator: "\n").map(String.init).first { $0.contains("(\(file))") }
                            ?? "- [\(name ?? file)](\(file))" + (memoryDescription(text).map { " — \($0)" } ?? "")
                        lines.append(line)
                    }
                }
                actions.append(FileAction(file: file, outcome: outcome))
            }
            if !lines.isEmpty { index = appending(lines, to: index) }
            planned.append(Source(folder: folder, origin: origin, files: actions, indexLines: lines))
        }
        let indexLines = index.split(separator: "\n", omittingEmptySubsequences: true).count
        return TargetPlan(target: target, sources: planned, indexLineCount: indexLines, indexByteCount: index.utf8.count)
    }

    static func appending(_ lines: [String], to index: String) -> String {
        guard !lines.isEmpty else { return index }
        var text = index
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text + lines.joined(separator: "\n") + "\n"
    }

    // MARK: Apply

    public struct Applied: Sendable, Equatable {
        public var copied: Int
        /// Files that appeared since the plan, or could not be written: left as they are.
        public var skipped: [String]
    }

    /// Writes the plan: each copy created without overwriting anything, then the index lines appended. Nothing
    /// is removed, from the sources or the targets.
    public static func apply(_ plan: Plan, projects: String) -> Applied {
        var copied = 0
        var skipped: [String] = []
        for target in plan.targets where target.copies > 0 {
            try? FileManager.default.createDirectory(atPath: target.target.directory, withIntermediateDirectories: true)
            var lines: [String] = []
            for source in target.sources {
                let directory = memoryPath(projects, source.folder)
                for action in source.files where action.outcome == .copy {
                    let from = (directory as NSString).appendingPathComponent(action.file)
                    let to = (target.target.directory as NSString).appendingPathComponent(action.file)
                    guard let data = FileManager.default.contents(atPath: from),
                          (try? data.write(to: URL(fileURLWithPath: to), options: .withoutOverwriting)) != nil else {
                        skipped.append(to)
                        continue
                    }
                    copied += 1
                    if let line = source.indexLines.first(where: { $0.contains("(\(action.file))") }) { lines.append(line) }
                }
            }
            let indexURL = URL(fileURLWithPath: target.target.directory).appending(path: indexFile, directoryHint: .notDirectory)
            let current = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
            let fresh = lines.filter { !current.contains($0) }
            guard !fresh.isEmpty else { continue }
            if (try? appending(fresh, to: current).write(to: indexURL, atomically: true, encoding: .utf8)) == nil {
                skipped.append(indexURL.path)
            }
        }
        return Applied(copied: copied, skipped: skipped)
    }

    // MARK: Report

    /// The plan as text: per target, each source and what happens to each of its files.
    public static func report(_ plan: Plan, applied: Applied? = nil, home: String = NSHomeDirectory()) -> String {
        func short(_ path: String) -> String {
            path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        var lines: [String] = []
        if let applied {
            lines.append("Copied \(applied.copied) memory \(applied.copied == 1 ? "file" : "files"). Nothing was deleted.")
            for path in applied.skipped { lines.append("  skipped \(short(path)) (appeared since, or could not be written)") }
        } else {
            lines.append("Dry run: nothing written. Run again with --apply to copy; nothing is ever deleted or overwritten.")
        }
        if plan.targets.isEmpty { lines.append(""); lines.append("No stray memory found.") }
        for target in plan.targets {
            lines.append("")
            let what = target.target.owner == .scope ? "scope \(target.target.label)" : "\(target.target.scope) · \(target.target.label)"
            lines.append("\(what) → \(short(target.target.directory))")
            for source in target.sources {
                let origin: String
                switch source.origin {
                case .taskRoot(let slug?): origin = "root of task \(slug)"
                case .taskRoot(nil): origin = "task folder, record gone"
                case .sandbox(let slug): origin = "sandbox of task \(slug)"
                case .otherClone(let path): origin = "another clone: \(short(path))"
                }
                lines.append("  from \(source.folder) (\(origin))")
                for action in source.files {
                    switch action.outcome {
                    case .copy: lines.append("    copy      \(action.file)")
                    case .identical(let file): lines.append("    duplicate \(action.file)" + (file == action.file ? "" : " (= \(file))"))
                    case .sameName(let file): lines.append("    same name \(action.file) — differs from \(file), kept the target's; compare by hand")
                    case .conflict: lines.append("    conflict  \(action.file) — a different memory has this file name; not copied")
                    }
                }
            }
            var summary = "  \(target.copies) to copy; index then \(target.indexLineCount) lines, \(target.indexByteCount / 1000) kB"
            if target.indexOverLimit { summary += " — over Claude Code's 200 lines / 25 kB: tidy MEMORY.md, the end is not loaded" }
            lines.append(summary)
        }
        if !plan.leftAlone.isEmpty {
            lines.append("")
            lines.append("Left alone (no scope of Scope's): " + plan.leftAlone.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
